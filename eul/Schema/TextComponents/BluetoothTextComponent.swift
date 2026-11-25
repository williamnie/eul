//
//  BluetoothTextComponent.swift
//  eul
//
//  Created by Gao Sun on 2026/11/25.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI
import SwiftyJSON

enum BluetoothTextComponent: String, CaseIterable, JSONCodabble, LocalizedTextComponent {
    case name
    case percentage

    static var defaultComponents: [Self] {
        [.percentage]
    }
}
