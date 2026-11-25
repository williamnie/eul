//
//  BluetoothStore.swift
//  eul
//
//  Created by Gao Sun on 2021/1/18.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Combine
import Darwin
import Foundation
import IOKit.ps

class BluetoothStore: ObservableObject, Refreshable {
    // IOPSCopyPowerSourcesByType 是 IOKit.ps 中用于按类型读取电源（包含外设电源）的原生 C 符号
    private typealias CopyPowerSourcesByTypeFn = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    private static let accessorySourceType: Int32 = 4

    private static let copyPowerSourcesByType: CopyPowerSourcesByTypeFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else {
            return nil
        }
        return unsafeBitCast(sym, to: CopyPowerSourcesByTypeFn.self)
    }()

    private let refreshQueue = DispatchQueue(label: "com.gao.eul.bluetooth", qos: .utility)
    private let minRefreshInterval: TimeInterval = 10
    private var lastFetchTime: Date = .distantPast
    private var activeCancellable: AnyCancellable?

    @Published var devices: [BluetoothDevice] = []

    var selectedDevice: BluetoothDevice? {
        let selection = SharedStore.componentConfig[.Bluetooth].bluetoothDeviceSelection
        if !selection.isEmpty, let matched = devices.first(where: { $0.id == selection }) {
            return matched
        }
        // 自动模式：优先显示鼠标类蓝牙设备，其次显示第一个设备
        return devices.first(where: { $0.category?.lowercased() == "mouse" }) ?? devices.first
    }

    var autoDeviceDescription: String {
        let base = "bluetooth.device.auto".localized()
        if let autoDevice = devices.first(where: { $0.category?.lowercased() == "mouse" }) ?? devices.first {
            return "\(base) (\(autoDevice.displayName))"
        }
        return base
    }

    private var isStatusBarActive: Bool {
        SharedStore.components.showComponents && SharedStore.components.activeComponents.contains(.Bluetooth)
    }

    init() {
        initObserver(for: .SMCShouldRefresh)
        DispatchQueue.main.async { [weak self] in
            self?.activeCancellable = SharedStore.components.$activeComponents.sink { [weak self] active in
                if active.contains(.Bluetooth) {
                    self?.fetch(force: true)
                }
            }
        }
        fetch(force: true)
    }

    @objc func refresh() {
        // 仅在状态栏启用了蓝牙组件时参与定时轮询，避免无谓消耗
        guard isStatusBarActive else {
            return
        }
        fetch(force: false)
    }

    func fetch(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastFetchTime) < minRefreshInterval {
            return
        }
        lastFetchTime = now

        refreshQueue.async { [weak self] in
            let fetched = Self.readAccessoryPowerSources()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.devices != fetched {
                    self.devices = fetched
                }
            }
        }
    }

    /// 通过 IOKit 外设电源接口读取蓝牙外设电量（无子进程、无需蓝牙 TCC 隐私权限）
    private static func readAccessoryPowerSources() -> [BluetoothDevice] {
        guard let fn = copyPowerSourcesByType else {
            return []
        }

        // 优先查询外设类型 (4)，若返回空则回退查询全部电源 (0)
        let blob: CFTypeRef? = fn(accessorySourceType)?.takeRetainedValue() ?? fn(0)?.takeRetainedValue()
        guard let powerBlob = blob,
              let list = IOPSCopyPowerSourcesList(powerBlob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return []
        }

        var result: [BluetoothDevice] = []
        var seenIDs = Set<String>()

        for item in list {
            guard let desc = IOPSGetPowerSourceDescription(powerBlob, item)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let sourceType = desc[kIOPSTypeKey as String] as? String
            let transport = desc[kIOPSTransportTypeKey as String] as? String

            // 仅保留蓝牙相关外设或 Accessory Source
            let isBluetoothTransport = transport?.localizedCaseInsensitiveContains("bluetooth") == true
            let isAccessorySource = sourceType == "Accessory Source"
            guard isBluetoothTransport || isAccessorySource else {
                continue
            }

            guard let name = desc[kIOPSNameKey as String] as? String, !name.isEmpty,
                  let currentCapacity = desc[kIOPSCurrentCapacityKey as String] as? Int
            else {
                continue
            }

            let maxCapacity = (desc[kIOPSMaxCapacityKey as String] as? Int) ?? 100
            let percentage: Int
            if maxCapacity > 0 {
                percentage = min(max(Int(round(Double(currentCapacity) * 100.0 / Double(maxCapacity))), 0), 100)
            } else {
                percentage = min(max(currentCapacity, 0), 100)
            }

            let accessoryID = desc["Accessory Identifier"] as? String
            let partID = desc["Part Identifier"] as? String
            let powerSourceID = (desc[kIOPSPowerSourceIDKey as String] as? Int).map(String.init) ?? name
            let baseID = accessoryID ?? powerSourceID
            let uniqueID = partID.map { "\(baseID)-\($0)" } ?? baseID

            guard !seenIDs.contains(uniqueID) else {
                continue
            }
            seenIDs.insert(uniqueID)

            let isChargingFlag = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            let powerState = desc[kIOPSPowerSourceStateKey as String] as? String
            let isCharging = isChargingFlag || powerState == kIOPSACPowerValue

            result.append(
                BluetoothDevice(
                    id: uniqueID,
                    name: name,
                    category: desc["Accessory Category"] as? String,
                    transportType: transport,
                    partIdentifier: partID,
                    batteryLevel: percentage,
                    isCharging: isCharging,
                    lowWarnLevel: desc["Low Warn Level"] as? Int
                )
            )
        }

        return result
    }
}
