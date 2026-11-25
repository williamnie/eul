//
//  BluetoothDevice.swift
//  eul
//
//  Created by Gao Sun on 2021/1/22.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

struct BluetoothDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let category: String?
    let transportType: String?
    let partIdentifier: String?
    let batteryLevel: Int
    let isCharging: Bool
    let lowWarnLevel: Int?

    var displayName: String {
        if let part = partIdentifier, !part.isEmpty {
            return "\(name) (\(part))"
        }
        return name
    }

    var percentageString: String {
        "\(batteryLevel)%"
    }
}
