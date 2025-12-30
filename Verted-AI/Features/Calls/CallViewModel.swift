import Foundation
import Combine
import SwiftUI

class CallViewModel: ObservableObject { 
    @Published var callSession: CallSession = CallSession()
    @Published var isLoading: Bool = false
    @Published var error: Error?
    @Published var isAccepting: Bool = false
    @Published var isDeclining: Bool = false
    @Published var isEnding: Bool = false
    @Published var isMuted: Bool = false
    @Published var isUnmuted: Bool = false
    @Published var isPaused: Bool = false
}

