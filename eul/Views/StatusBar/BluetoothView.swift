//
//  BluetoothView.swift
//  eul
//
//  Created by Gao Sun on 2026/11/25.
//  Copyright © 2026 Gao Sun. All rights reserved.
//

import SwiftUI

struct BluetoothView: View {
    @EnvironmentObject var bluetoothStore: BluetoothStore
    @EnvironmentObject var componentConfigStore: ComponentConfigStore
    @EnvironmentObject var textStore: ComponentsStore<BluetoothTextComponent>

    var config: EulComponentConfig {
        componentConfigStore[.Bluetooth]
    }

    var texts: [String] {
        guard let device = bluetoothStore.selectedDevice else {
            return ["N/A"]
        }

        return textStore.activeComponents.map {
            switch $0 {
            case .name:
                return device.displayName
            case .percentage:
                return device.percentageString
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if config.showIcon {
                Image("Bluetooth")
                    .resizable()
                    .frame(width: 13, height: 13)
            }
            if textStore.showComponents {
                StatusBarTextView(texts: texts)
                    .stableWidth()
            }
        }
    }
}
