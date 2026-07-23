//
//  Item.swift
//  fjallkartan
//
//  Created by Wallman, Daniel on 2026-07-23.
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
