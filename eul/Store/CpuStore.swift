//
//  CpuStore.swift
//  eul
//
//  Created by Gao Sun on 2020/6/27.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import Darwin
import Foundation
import SharedLibrary
import SystemKit
import WidgetKit

class CpuStore: ObservableObject, Refreshable {
    private var previousCPULoad = host_cpu_load_info()
    private var hasPreviousCPULoad = false

    @Published var temp: Double?
    @Published var usageCPU: (system: Double, user: Double, idle: Double, nice: Double)?
    @Published var loadAverage: [Double]?
    @Published var physicalCores = 0
    @Published var logicalCores = 0
    @Published var upTime: (days: Int, hrs: Int, mins: Int, secs: Int)?
    @Published var thermalLevel: System.ThermalLevel = .Unknown
    @Published var usageHistory: [Double] = []

    var loadAverage1MinString: String {
        formatDouble(loadAverage?[safe: 0])
    }

    var loadAverage5MinString: String {
        formatDouble(loadAverage?[safe: 1])
    }

    var loadAverage15MinString: String {
        formatDouble(loadAverage?[safe: 2])
    }

    var usageString: String {
        guard let usage = usageCPU else {
            return "N/A"
        }
        return String(format: "%.0f%%", usage.system + usage.user)
    }

    var upTimeDaysString: String {
        guard let upTime = upTime else {
            return "N/A"
        }
        return "\(upTime.days)"
    }

    var usage: Double? {
        guard let usageCPU = usageCPU else {
            return nil
        }
        return usageCPU.system + usageCPU.user
    }

    private func formatDouble(_ value: Double?) -> String {
        guard let value = value else {
            return "N/A"
        }
        return String(format: "%.2f", value)
    }

    private func getInfo() {
        physicalCores = System.physicalCores()
        logicalCores = System.logicalCores()
        upTime = System.uptime()
        thermalLevel = System.thermalLevel()
    }

    /// 使用 UInt32 溢出安全减法计算 CPU 占用，避免长时间运行后 cpu_ticks 32 位回绕导致 SystemKit 算术溢出崩溃
    private func safeUsageCPU() -> (system: Double, user: Double, idle: Double, nice: Double) {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var load = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, 0, 0, 0)
        }

        guard hasPreviousCPULoad else {
            previousCPULoad = load
            hasPreviousCPULoad = true
            return (0, 0, 0, 0)
        }

        let userDiff = Double(load.cpu_ticks.0 &- previousCPULoad.cpu_ticks.0)
        let sysDiff = Double(load.cpu_ticks.1 &- previousCPULoad.cpu_ticks.1)
        let idleDiff = Double(load.cpu_ticks.2 &- previousCPULoad.cpu_ticks.2)
        let niceDiff = Double(load.cpu_ticks.3 &- previousCPULoad.cpu_ticks.3)

        previousCPULoad = load

        let totalTicks = userDiff + sysDiff + idleDiff + niceDiff
        guard totalTicks > 0 else {
            return (0, 0, 0, 0)
        }

        return (
            system: sysDiff / totalTicks * 100.0,
            user: userDiff / totalTicks * 100.0,
            idle: idleDiff / totalTicks * 100.0,
            nice: niceDiff / totalTicks * 100.0
        )
    }

    private func getUsage() {
        let usage = safeUsageCPU()
        usageCPU = usage
        loadAverage = System.loadAverage()
        usageHistory = (usageHistory + [usage.system + usage.user]).suffix(LineChart.defaultMaxPointCount)
    }

    private func getTemp() {
        temp = (SmcControl.shared.cpuDieTemperature ?? 0) > 0
            ? SmcControl.shared.cpuDieTemperature
            : SmcControl.shared.cpuProximityTemperature
    }

    @objc func refresh() {
        getInfo()
        getUsage()
        getTemp()
        writeToContainer()
    }

    func writeToContainer() {
        Container.set(CpuEntry(
            temp: temp,
            usageSystem: usageCPU?.system,
            usageUser: usageCPU?.user,
            usageNice: usageCPU?.nice
        ))
        if #available(OSX 11, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: CpuEntry.kind)
        }
    }

    init() {
        initObserver(for: .StoreShouldRefresh)
    }
}
