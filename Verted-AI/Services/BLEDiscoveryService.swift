import Foundation
import CoreBluetooth

/// Delegate protocol for BLE peer discovery events
protocol BLEDiscoveryServiceDelegate: AnyObject {
    /// Called when a new peer is discovered
    func onPeerDiscovered(peerId: String)
    /// Called when a previously discovered peer is no longer available
    func onPeerLost(peerId: String)
}

/// Service for discovering nearby peers using Bluetooth Low Energy
/// Handles both advertising (making this device discoverable) and scanning (finding other devices)
class BLEDiscoveryService: NSObject {
    
    // MARK: - Properties
    
    /// Delegate to receive peer discovery callbacks
    weak var delegate: BLEDiscoveryServiceDelegate?
    
    /// Background queue for all BLE operations to avoid blocking main thread
    private let bleQueue = DispatchQueue(label: "com.vertedai.ble.discovery", qos: .userInitiated)
    
    /// Central manager for scanning nearby peripherals
    private var centralManager: CBCentralManager!
    
    /// Peripheral manager for advertising this device
    private var peripheralManager: CBPeripheralManager!
    
    /// Custom service UUID for peer discovery
    /// This UUID identifies our app's BLE service
    private let serviceUUID = CBUUID(string: "A7CE1234-1234-1234-1234-123456789ABC")
    
    /// Characteristic UUID for peer identifier
    private let peerIdentifierCharacteristicUUID = CBUUID(string: "A7CE5678-5678-5678-5678-567890DEF012")
    
    /// This device's peer identifier to advertise
    private var peerIdentifier: String?
    
    /// Dictionary tracking discovered peers with their last seen timestamp
    /// Key: peerId (String), Value: lastSeen (Date)
    private var discoveredPeers: [String: Date] = [:]
    
    /// Dictionary mapping peripheral identifiers to their peer identifiers
    /// Key: peripheral UUID (String), Value: peerId (String)
    private var peripheralToPeerId: [String: String] = [:]
    
    /// Set of peripherals we're currently connected to or connecting to
    private var connectedPeripherals: Set<UUID> = []
    
    /// Lock for thread-safe access to discoveredPeers and peripheralToPeerId dictionaries
    private let peersLock = NSLock()
    
    /// Timer for cleaning up stale peers (not seen for 5+ seconds)
    private var cleanupTimer: Timer?
    
    /// Service characteristic for advertising peer identifier
    private var serviceCharacteristic: CBMutableCharacteristic?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        // Initialize managers on background queue
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.centralManager = CBCentralManager(delegate: self, queue: self.bleQueue)
            self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.bleQueue)
        }
    }
    
    // MARK: - Public Methods
    
    /// Start BLE discovery with the given peer identifier
    /// - Parameter peerIdentifier: Unique identifier for this device/peer
    func startDiscovery(peerIdentifier: String) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.peerIdentifier = peerIdentifier
            self.startCleanupTimer()
            
            // Start advertising if peripheral manager is ready
            if self.peripheralManager.state == .poweredOn {
                self.startAdvertising()
            }
            
            // Start scanning if central manager is ready
            if self.centralManager.state == .poweredOn {
                self.startScanning()
            }
        }
    }
    
    /// Stop BLE discovery and cleanup resources
    func stopDiscovery() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopAdvertising()
            self.stopScanning()
            self.stopCleanupTimer()
            
            // Clear all discovered peers
            self.peersLock.lock()
            let lostPeers = Array(self.discoveredPeers.keys)
            self.discoveredPeers.removeAll()
            self.peersLock.unlock()
            
            // Notify delegate about lost peers on main thread
            DispatchQueue.main.async {
                lostPeers.forEach { peerId in
                    self.delegate?.onPeerLost(peerId: peerId)
                }
            }
        }
    }
    
    /// Get list of currently discovered peer IDs
    /// - Returns: Array of peer identifiers
    func getDiscoveredPeers() -> [String] {
        peersLock.lock()
        let peers = Array(discoveredPeers.keys)
        peersLock.unlock()
        return peers
    }
    
    // MARK: - Private Methods
    
    /// Start advertising this device as a BLE peripheral
    private func startAdvertising() {
        guard let peerId = peerIdentifier else {
            print("[BLEDiscoveryService] Cannot start advertising: peerIdentifier is nil")
            return
        }
        
        // Create service with peer identifier characteristic
        let service = CBMutableService(type: serviceUUID, primary: true)
        
        // Create characteristic for peer identifier
        let characteristic = CBMutableCharacteristic(
            type: peerIdentifierCharacteristicUUID,
            properties: [.read],
            value: peerId.data(using: .utf8),
            permissions: [.readable]
        )
        
        service.characteristics = [characteristic]
        serviceCharacteristic = characteristic
        
        // Add service to peripheral manager
        peripheralManager.add(service)
        
        // Start advertising with service UUID and include peer identifier in service data
        // Note: Service data is included in advertisement when possible
        var advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "VertedAI"
        ]
        
        // Include peer identifier in service data (if supported)
        if let peerIdData = peerId.data(using: .utf8) {
            advertisementData[CBAdvertisementDataServiceDataKey] = [serviceUUID: peerIdData]
        }
        
        peripheralManager.startAdvertising(advertisementData)
        print("[BLEDiscoveryService] Started advertising with peerId: \(peerId)")
    }
    
    /// Stop advertising
    private func stopAdvertising() {
        peripheralManager.stopAdvertising()
        print("[BLEDiscoveryService] Stopped advertising")
    }

    /// Start scanning for nearby peripherals
    private func startScanning() {
        // Scan for peripherals with our service UUID
        // Allow duplicates to get continuous updates
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        print("[BLEDiscoveryService] Started scanning for peripherals")
    }
    
    /// Stop scanning
    private func stopScanning() {
        centralManager.stopScan()
        print("[BLEDiscoveryService] Stopped scanning")
    }
    
    /// Start timer to periodically clean up stale peers
    private func startCleanupTimer() {
        stopCleanupTimer()
        
        // Run cleanup every 2 seconds
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.cleanupStalePeers()
        }
    }
    
    /// Stop cleanup timer
    private func stopCleanupTimer() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }
    
    /// Remove peers that haven't been seen for 5+ seconds
    private func cleanupStalePeers() {
        let now = Date()
        let staleThreshold: TimeInterval = 5.0
        
        peersLock.lock()
        
        // Find peers that are stale
        let stalePeers = discoveredPeers.compactMap { (peerId, lastSeen) -> String? in
            if now.timeIntervalSince(lastSeen) >= staleThreshold {
                return peerId
            }
            return nil
        }
        
        // Remove stale peers
        stalePeers.forEach { peerId in
            discoveredPeers.removeValue(forKey: peerId)
        }
        
        peersLock.unlock()
        
        // Notify delegate about lost peers on main thread
        if !stalePeers.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                stalePeers.forEach { peerId in
                    self.delegate?.onPeerLost(peerId: peerId)
                }
            }
        }
    }
    
    /// Update or add a discovered peer
    /// - Parameters:
    ///   - peerId: The peer identifier
    ///   - timestamp: When the peer was seen
    private func updateDiscoveredPeer(peerId: String, timestamp: Date) {
        peersLock.lock()
        
        let isNewPeer = discoveredPeers[peerId] == nil
        discoveredPeers[peerId] = timestamp
        
        peersLock.unlock()
        
        // Notify delegate about new peer on main thread
        if isNewPeer {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.onPeerDiscovered(peerId: peerId)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEDiscoveryService: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[BLEDiscoveryService] Central manager state updated: \(central.state.rawValue)")
        
        switch central.state {
        case .poweredOn:
            // Start scanning when Bluetooth is powered on
            startScanning()
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // Stop scanning if Bluetooth is unavailable
            stopScanning()
        case .unknown:
            // Wait for state update
            break
        @unknown default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Check if we have service UUIDs in advertisement
        guard let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
              serviceUUIDs.contains(serviceUUID) else {
            return
        }
        
        let peripheralId = peripheral.identifier.uuidString
        
        // Try to extract peer identifier from advertisement service data first
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let peerIdData = serviceData[serviceUUID],
           let peerId = String(data: peerIdData, encoding: .utf8) {
            
            // Found peer identifier in advertisement data
            peersLock.lock()
            peripheralToPeerId[peripheralId] = peerId
            peersLock.unlock()
            
            updateDiscoveredPeer(peerId: peerId, timestamp: Date())
            print("[BLEDiscoveryService] Discovered peer from advertisement: \(peerId), RSSI: \(RSSI)")
        } else {
            // Peer identifier not in advertisement data, need to connect and read characteristic
            // Check if we already know this peripheral's peer ID
            peersLock.lock()
            let knownPeerId = peripheralToPeerId[peripheralId]
            let isConnecting = connectedPeripherals.contains(peripheral.identifier)
            peersLock.unlock()
            
            if let peerId = knownPeerId {
                // We already know this peer's ID, just update timestamp
                updateDiscoveredPeer(peerId: peerId, timestamp: Date())
            } else if !isConnecting {
                // Connect to read the peer identifier characteristic
                connectToPeripheral(peripheral)
            }
        }
    }
    
    /// Connect to a peripheral to read its peer identifier
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        peersLock.lock()
        connectedPeripherals.insert(peripheral.identifier)
        peersLock.unlock()
        
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        print("[BLEDiscoveryService] Connecting to peripheral: \(peripheral.identifier.uuidString)")
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLEDiscoveryService] Connected to peripheral: \(peripheral.identifier.uuidString)")
        
        // Discover services to find our service
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLEDiscoveryService] Failed to connect to peripheral: \(peripheral.identifier.uuidString), error: \(error?.localizedDescription ?? "unknown")")
        
        peersLock.lock()
        connectedPeripherals.remove(peripheral.identifier)
        peersLock.unlock()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLEDiscoveryService] Disconnected from peripheral: \(peripheral.identifier.uuidString)")
        
        peersLock.lock()
        connectedPeripherals.remove(peripheral.identifier)
        peersLock.unlock()
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEDiscoveryService: CBPeripheralManagerDelegate {
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        print("[BLEDiscoveryService] Peripheral manager state updated: \(peripheral.state.rawValue)")
        
        switch peripheral.state {
        case .poweredOn:
            // Start advertising when Bluetooth is powered on
            startAdvertising()
        case .poweredOff, .unauthorized, .unsupported, .resetting:
            // Stop advertising if Bluetooth is unavailable
            stopAdvertising()
        case .unknown:
            // Wait for state update
            break
        @unknown default:
            break
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            print("[BLEDiscoveryService] Error starting advertising: \(error.localizedDescription)")
        } else {
            print("[BLEDiscoveryService] Successfully started advertising")
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("[BLEDiscoveryService] Error adding service: \(error.localizedDescription)")
        } else {
            print("[BLEDiscoveryService] Successfully added service: \(service.uuid)")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEDiscoveryService: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("[BLEDiscoveryService] Error discovering services: \(error.localizedDescription)")
            peersLock.lock()
            connectedPeripherals.remove(peripheral.identifier)
            peersLock.unlock()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            print("[BLEDiscoveryService] Service not found on peripheral")
            peersLock.lock()
            connectedPeripherals.remove(peripheral.identifier)
            peersLock.unlock()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        // Discover characteristics
        peripheral.discoverCharacteristics([peerIdentifierCharacteristicUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("[BLEDiscoveryService] Error discovering characteristics: \(error.localizedDescription)")
            peersLock.lock()
            connectedPeripherals.remove(peripheral.identifier)
            peersLock.unlock()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == peerIdentifierCharacteristicUUID }) else {
            print("[BLEDiscoveryService] Characteristic not found")
            peersLock.lock()
            connectedPeripherals.remove(peripheral.identifier)
            peersLock.unlock()
            centralManager.cancelPeripheralConnection(peripheral)
            return
        }
        
        // Read the peer identifier
        peripheral.readValue(for: characteristic)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("[BLEDiscoveryService] Error reading characteristic: \(error.localizedDescription)")
        } else if let data = characteristic.value,
                  let peerId = String(data: data, encoding: .utf8) {
            
            let peripheralId = peripheral.identifier.uuidString
            
            // Store mapping and update discovered peer
            peersLock.lock()
            peripheralToPeerId[peripheralId] = peerId
            peersLock.unlock()
            
            updateDiscoveredPeer(peerId: peerId, timestamp: Date())
            print("[BLEDiscoveryService] Read peer identifier: \(peerId) from peripheral: \(peripheralId)")
        }
        
        // Disconnect after reading
        peersLock.lock()
        connectedPeripherals.remove(peripheral.identifier)
        peersLock.unlock()
        centralManager.cancelPeripheralConnection(peripheral)
    }
}

