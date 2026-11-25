//
//  Info.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Darwin
import Foundation
import IOKit.ps
import SharedLibrary
import SystemConfiguration
import SystemKit

extension BatteryEntry.BatteryCondition {
    var description: String {
        "battery.condition.\(rawValue)".localized()
    }
}

extension BatteryEntry.PowerSourceState {
    var description: String {
        "battery.power_source.\(rawValue)".localized()
    }
}

enum Info {
    static var isBigSur: Bool {
        if #available(OSX 11, *) {
            return true
        }
        return false
    }

    struct Battery {
        var currentCapacity = 0
        var maxCapacity = 0
        var currentCharge: Double {
            Double(currentCapacity) / Double(maxCapacity)
        }

        var condition: BatteryEntry.BatteryCondition = .good
        var powerSource: BatteryEntry.PowerSourceState = .unknown
        var timeToFullCharge = 0
        var timeToEmpty = 0
        var isCharged = false
        var isCharging = false

        init() {
            guard
                let blob = IOPSCopyPowerSourcesInfo(),
                let list = IOPSCopyPowerSourcesList(blob.takeRetainedValue()),
                let array = list.takeRetainedValue() as? [Any],
                array.count > 0,
                let dict = array[0] as? NSDictionary
            else {
                return
            }

            currentCapacity = dict[kIOPSCurrentCapacityKey] as? Int ?? 0
            maxCapacity = dict[kIOPSMaxCapacityKey] as? Int ?? 0
            timeToFullCharge = dict[kIOPSTimeToFullChargeKey] as? Int ?? 0
            timeToEmpty = dict[kIOPSTimeToEmptyKey] as? Int ?? 0
            isCharged = dict[kIOPSIsChargedKey] as? Bool ?? false
            isCharging = dict[kIOPSIsChargingKey] as? Bool ?? false

            if let value = dict[kIOPSBatteryHealthConditionKey] as? String {
                switch value {
                case kIOPSPoorValue:
                    condition = .poor
                case kIOPSFairValue:
                    condition = .fair
                default:
                    condition = .good
                }
            }

            if let value = dict[kIOPSPowerSourceStateKey] as? String {
                switch value {
                case kIOPSACPowerValue:
                    powerSource = .acPower
                case kIOPSBatteryPowerValue:
                    powerSource = .battery
                default:
                    powerSource = .unknown
                }
            }

            Print(
                "🔋 battery info",
                currentCapacity,
                maxCapacity,
                timeToFullCharge,
                timeToEmpty,
                isCharged,
                isCharging,
                condition,
                powerSource
            )
        }
    }

    struct NetworkUsage {
        var inBytes: UInt64
        var outBytes: UInt64
    }

    struct NetworkPort: Identifiable {
        var port: String?
        var device: String

        var id: String {
            device
        }

        var description: String {
            guard let port = port else {
                return device
            }
            return "\(port) (\(device))"
        }
    }

    private static let networkQueue = DispatchQueue(label: "com.gao.eul.network", qos: .utility)

    struct InterfaceStats {
        var name: String
        var inBytes: UInt64
        var outBytes: UInt64
        var isActive: Bool
    }

    /// 使用 SystemConfiguration 原生 API 按系统服务顺序获取网络端口列表，替代 `networksetup -listnetworkserviceorder`
    static func getNetworkPorts() -> [NetworkPort] {
        var ports = [NetworkPort]()
        var seenDevices = Set<String>()

        if
            let prefs = SCPreferencesCreate(nil, "eul" as CFString, nil),
            let networkSet = SCNetworkSetCopyCurrent(prefs),
            let serviceOrder = SCNetworkSetGetServiceOrder(networkSet) as? [String]
        {
            for serviceID in serviceOrder {
                guard
                    let service = SCNetworkServiceCopy(prefs, serviceID as CFString),
                    SCNetworkServiceGetEnabled(service),
                    let interface = SCNetworkServiceGetInterface(service),
                    let device = SCNetworkInterfaceGetBSDName(interface) as String?,
                    !seenDevices.contains(device)
                else {
                    continue
                }
                seenDevices.insert(device)
                let portName = (SCNetworkServiceGetName(service) as String?)
                    ?? (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?)
                ports.append(NetworkPort(port: portName, device: device))
            }
        }

        // 若偏好配置中未取到，兜底使用 SCNetworkInterfaceCopyAll
        if ports.isEmpty, let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                guard
                    let device = SCNetworkInterfaceGetBSDName(interface) as String?,
                    !seenDevices.contains(device)
                else {
                    continue
                }
                seenDevices.insert(device)
                let portName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
                ports.append(NetworkPort(port: portName, device: device))
            }
        }

        return ports
    }

    /// 获取当前默认主路由网卡名（如 en0）
    private static func getPrimaryInterfaceName() -> String? {
        guard
            let store = SCDynamicStoreCreate(nil, "eul" as CFString, nil, nil),
            let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
            let primary = dict["PrimaryInterface"] as? String
        else {
            return nil
        }
        return primary
    }

    /// 使用 sysctl(NET_RT_IFLIST2) 一次性读取所有网卡 64 位流量计数与运行状态，替代 `ifconfig` 和 `netstat -bI`
    private static func getAllInterfaceStats() -> [String: InterfaceStats] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else {
            return [:]
        }

        var buffer = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &len, nil, 0) == 0 else {
            return [:]
        }

        var result = [String: InterfaceStats]()
        buffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let ptr = baseAddress.advanced(by: offset)
                let ifm = ptr.assumingMemoryBound(to: if_msghdr.self).pointee
                let msgLen = Int(ifm.ifm_msglen)
                guard msgLen > 0, offset + msgLen <= len else {
                    break
                }

                if ifm.ifm_type == UInt8(RTM_IFINFO2), msgLen >= MemoryLayout<if_msghdr2>.stride + MemoryLayout<sockaddr_dl>.size {
                    let if2m = ptr.assumingMemoryBound(to: if_msghdr2.self).pointee
                    let sdlPtr = ptr.advanced(by: MemoryLayout<if_msghdr2>.stride).assumingMemoryBound(to: sockaddr_dl.self)
                    let nameLen = Int(sdlPtr.pointee.sdl_nlen)
                    if nameLen > 0, let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) {
                        let namePtr = UnsafeRawPointer(sdlPtr).advanced(by: nameOffset).assumingMemoryBound(to: UInt8.self)
                        if let name = String(bytes: UnsafeBufferPointer(start: namePtr, count: nameLen), encoding: .utf8) {
                            let flags = if2m.ifm_flags
                            let isActive = (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
                                && (flags & IFF_LOOPBACK) == 0
                            result[name] = InterfaceStats(
                                name: name,
                                inBytes: if2m.ifm_data.ifi_ibytes,
                                outBytes: if2m.ifm_data.ifi_obytes,
                                isActive: isActive
                            )
                        }
                    }
                }

                offset += msgLen
            }
        }
        return result
    }

    static func getNetworkUsage(forDevice: String?, _ onData: @escaping (NetworkUsage, [NetworkPort], NetworkPort?) -> Void) {
        networkQueue.async {
            let services = getNetworkPorts()
            let statsMap = getAllInterfaceStats()
            let primaryName = getPrimaryInterfaceName()

            let currentActivePort: NetworkPort? = {
                if let primaryName = primaryName, let matched = services.first(where: { $0.device == primaryName }) {
                    return matched
                }
                return services.first(where: { statsMap[$0.device]?.isActive == true })
            }()

            let device = forDevice ?? currentActivePort?.device ?? primaryName ?? "en0"
            let stats = statsMap[device]

            Print("network services order", services)
            Print("network current active interface", currentActivePort ?? "N/A")

            let usage = NetworkUsage(
                inBytes: stats?.inBytes ?? 0,
                outBytes: stats?.outBytes ?? 0
            )

            DispatchQueue.main.async {
                onData(usage, services, currentActivePort)
            }
        }
    }

    static var system = System()

    /// 使用原生 Darwin proc_pidpath 获取进程路径，替代 `ps -p <pid> -o comm=` 避免频繁 fork 子进程
    static func getProcessCommand(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let ret = proc_pidpath(pid_t(pid), &buffer, UInt32(buffer.count))
        guard ret > 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
