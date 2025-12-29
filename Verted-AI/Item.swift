//
//  Item.swift
//  Verted-AI
//
//  Created by MacBook Pro on 12/29/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
