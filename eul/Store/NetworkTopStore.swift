//
//  NetworkTopStore.swift
//  eul
//
//  Created by Gao Sun on 2020/10/17.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

class NetworkTopStore: ObservableObject {
    struct NetworkSpeed: CustomStringConvertible {
        var inSpeedInByte: Double = 0
        var outSpeedInByte: Double = 0

        var totalSpeedInByte: Double {
            inSpeedInByte + outSpeedInByte
        }

        var description: String {
            fatalError("not implemented")
        }
    }

    struct ProcessNetworkUsage: ProcessUsage {
        typealias T = NetworkSpeed
        let pid: Int
        let command: String
        let value: NetworkSpeed
        let runningApp: NSRunningApplication?
    }

    private let queue = DispatchQueue(label: "com.gao.eul.networkTop", qos: .utility)
    private var isRunning = false
    private var timer: Timer?
    private var activeCancellable: AnyCancellable?
    private var lastTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var lastInBytes: [Int: Double] = [:]
    private var lastOutBytes: [Int: Double] = [:]
    @ObservedObject var preferenceStore = SharedStore.preference
    @Published var processes: [ProcessNetworkUsage] = []

    private var interval: Int {
        preferenceStore.networkRefreshRate
    }

    var totalSpeed: NetworkSpeed {
        processes.reduce(into: NetworkSpeed()) { result, usage in
            result.inSpeedInByte += usage.value.inSpeedInByte
            result.outSpeedInByte += usage.value.outSpeedInByte
        }
    }

    private func run() {
        queue.async { [weak self] in
            guard let self = self, !self.isRunning else {
                return
            }
            self.isRunning = true
            defer { self.isRunning = false }

            guard let string = shell("nettop -L 1 -P -x -J bytes_in,bytes_out") else {
                print("unable to fetch network activity, please make sure nettop is available")
                return
            }

            let rows = string.split(separator: "\n").map { String($0) }
            guard let firstRow = rows.first else {
                return
            }

            let headers = firstRow
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0.lowercased()) }
            let processIndex = 0

            guard
                let inBytesIndex = headers.firstIndex(of: "bytes_in"),
                let outBytesIndex = headers.firstIndex(of: "bytes_out")
            else {
                return
            }

            let runningApps = NSWorkspace.shared.runningApplications
            let time = Date().timeIntervalSince1970
            let timeElapsed = time - self.lastTimestamp
            self.lastTimestamp = time

            guard timeElapsed > 0 else {
                return
            }

            Print("network top is updating")
            let result: [ProcessNetworkUsage] = rows.dropFirst().compactMap { row in
                let cols = row.split(separator: ",").map { String($0) }

                guard
                    cols.indices.contains(processIndex),
                    cols.indices.contains(inBytesIndex),
                    cols.indices.contains(outBytesIndex)
                else {
                    return nil
                }

                let processCol = cols[processIndex]
                let splitted = processCol.split(separator: ".").map { String($0) }

                guard
                    let last = splitted.last,
                    let pid = Int(last),
                    let inBytes = Double(cols[inBytesIndex]),
                    let outBytes = Double(cols[outBytesIndex])
                else {
                    return nil
                }

                let lastIn = self.lastInBytes[pid]
                let lastOut = self.lastOutBytes[pid]

                self.lastInBytes[pid] = inBytes
                self.lastOutBytes[pid] = outBytes

                if lastIn == nil, lastOut == nil {
                    return nil
                }

                let speed = NetworkSpeed(
                    inSpeedInByte: lastIn.map { $0 > inBytes ? 0 : (inBytes - $0) / timeElapsed } ?? 0,
                    outSpeedInByte: lastOut.map { $0 > outBytes ? 0 : (outBytes - $0) / timeElapsed } ?? 0
                )

                guard speed.totalSpeedInByte >= 100 else {
                    return nil
                }

                return ProcessNetworkUsage(
                    pid: pid,
                    command: Info.getProcessCommand(pid: pid) ?? splitted[0],
                    value: speed,
                    runningApp: runningApps.first(where: { $0.processIdentifier == pid })
                )
            }
            .sorted(by: { $0.value.totalSpeedInByte > $1.value.totalSpeedInByte })

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.timer != nil else {
                    return
                }
                self.processes = result
            }
        }
    }

    func update(shouldStart: Bool) {
        guard shouldStart else {
            timer?.invalidate()
            timer = nil
            return
        }

        if timer != nil {
            Print("network task already started")
            return
        }

        queue.async { [weak self] in
            self?.lastInBytes.removeAll()
            self?.lastOutBytes.removeAll()
            self?.lastTimestamp = Date().timeIntervalSince1970
        }
        processes = []

        let timer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: true) { [weak self] _ in
            self?.run()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    init() {
        activeCancellable = Publishers
            .CombineLatest3(
                preferenceStore.$showNetworkTopActivities,
                SharedStore.menuComponents.$activeComponents,
                SharedStore.ui.$menuOpened
            )
            .map {
                $0 && $1.contains(.Network) && $2
            }
            .sink { [self] in
                update(shouldStart: $0)
            }
    }
}
