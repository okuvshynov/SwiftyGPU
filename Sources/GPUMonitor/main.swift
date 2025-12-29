//
//  main.swift
//  GPUMonitor
//
//  High-resolution GPU load monitoring with JSONL output
//

import Foundation
import IOKit
import Darwin.Mach

// MARK: - IOKit Queries

func getAccelerators() -> [[String: AnyObject]] {
    var accelerators: [[String: AnyObject]] = []
    var iterator = io_iterator_t()
    if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess {
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            var serviceDict: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &serviceDict, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = serviceDict else { continue }
            accelerators.append(Dictionary(uniqueKeysWithValues: (dict.takeRetainedValue() as NSDictionary as Dictionary).map { ($0 as! String, $1) }))
        }
    }
    return accelerators
}

func getPCIDevices() -> [[String: AnyObject]] {
    var devices: [[String: AnyObject]] = []
    var iterator = io_iterator_t()
    if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOPCIDevice"), &iterator) == kIOReturnSuccess {
        defer { IOObjectRelease(iterator) }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            var serviceDict: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &serviceDict, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = serviceDict else { continue }
            devices.append(Dictionary(uniqueKeysWithValues: (dict.takeRetainedValue() as NSDictionary as Dictionary).map { ($0 as! String, $1) }))
        }
    }
    return devices
}

func devicesMatch(accelerator: [String: AnyObject], pciDevice: [String: AnyObject]) -> Bool {
    let vendorID = (pciDevice["vendor-id"] as? Data)?.withUnsafeBytes { $0.bindMemory(to: UInt32.self).first } ?? 0xFFFF
    let deviceID = (pciDevice["device-id"] as? Data)?.withUnsafeBytes { $0.bindMemory(to: UInt32.self).first } ?? 0xFFFF

    guard let pciMatch = (accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String)?.uppercased(),
          vendorID != 0xFFFF else { return false }

    if deviceID != 0xFFFF {
        let combo = deviceID << 16 | vendorID
        return pciMatch.contains(String(combo, radix: 16).uppercased())
    } else {
        let vendorHex = String(vendorID, radix: 16).uppercased()
        return pciMatch.hasSuffix(vendorHex) || pciMatch.contains(vendorHex + " ")
    }
}

// MARK: - Device Info (cached at startup)

struct DeviceInfo {
    let index: Int
    let name: String
    let totalVRAMMiB: Int?
    let pciMatch: String  // Used to re-match accelerator on each poll

    init(index: Int, accelerator: [String: AnyObject], pciDevice: [String: AnyObject]) {
        self.index = index
        self.pciMatch = accelerator["IOPCIMatch"] as? String ?? accelerator["IOPCIPrimaryMatch"] as? String ?? ""

        // Extract name
        let nameCandidates: [String?] = [
            (pciDevice["model"] as? Data).flatMap { String(data: $0, encoding: .utf8) },
            accelerator["IOGLBundleName"] as? String
        ]
        let rawName = nameCandidates.compactMap { $0 }.first ?? "<unknown>"
        self.name = String(rawName.prefix(while: { $0 != "\u{0}" }))

        // Extract total VRAM
        if let totalMiB = (accelerator["VRAM,totalMB"] as? NSNumber)?.intValue {
            self.totalVRAMMiB = totalMiB
        } else if let totalMiB = (pciDevice["VRAM,totalMB"] as? NSNumber)?.intValue {
            self.totalVRAMMiB = totalMiB
        } else if let totalB = (pciDevice["ATY,memsize"] as? NSNumber)?.intValue {
            self.totalVRAMMiB = totalB >> 20
        } else {
            self.totalVRAMMiB = nil
        }
    }
}

// MARK: - Output Structures

struct DeviceSample: Codable {
    let index: Int
    let name: String
    let usedVRAMBytes: Int?
    let totalVRAMBytes: Int?
    let utilizationPercent: Int?
}

struct Sample: Codable {
    let timestampMs: Int64
    let devices: [DeviceSample]
}

// MARK: - Sampling

func sampleDevices(deviceInfos: [DeviceInfo]) -> Sample {
    let accelerators = getAccelerators()
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)

    var deviceSamples: [DeviceSample] = []

    for info in deviceInfos {
        // Find matching accelerator by pciMatch
        guard let acc = accelerators.first(where: {
            let match = $0["IOPCIMatch"] as? String ?? $0["IOPCIPrimaryMatch"] as? String ?? ""
            return match == info.pciMatch
        }) else {
            deviceSamples.append(DeviceSample(
                index: info.index,
                name: info.name,
                usedVRAMBytes: nil,
                totalVRAMBytes: info.totalVRAMMiB.map { $0 << 20 },
                utilizationPercent: nil
            ))
            continue
        }

        var usedVRAMMiB: Int?
        var utilizationPercent: Int?

        if let stats = acc["PerformanceStatistics"] as? [String: AnyObject] {
            // VRAM usage
            let totalMiB = info.totalVRAMMiB ?? 0
            let memCandidates: [Int?] = [
                (stats["vramUsedBytes"] as? NSNumber)?.intValue,
                (stats["vramFreeBytes"] as? NSNumber).map { (totalMiB << 20) - $0.intValue },
                (stats["gartUsedBytes"] as? NSNumber)?.intValue,
                (stats["gartFreeBytes"] as? NSNumber).map { (totalMiB << 20) - $0.intValue }
            ]
            usedVRAMMiB = memCandidates.compactMap { $0 }.first.map { $0 >> 20 }

            // Utilization
            let utilCandidates: [Int?] = [
                (stats["Device Utilization %"] as? NSNumber)?.intValue,
                (stats["hardwareWaitTime"] as? NSNumber).map { max(min($0.intValue / 1000 / 1000 / 10, 100), 0) }
            ]
            utilizationPercent = utilCandidates.compactMap { $0 }.first
        }

        deviceSamples.append(DeviceSample(
            index: info.index,
            name: info.name,
            usedVRAMBytes: usedVRAMMiB.map { $0 << 20 },
            totalVRAMBytes: info.totalVRAMMiB.map { $0 << 20 },
            utilizationPercent: utilizationPercent
        ))
    }

    return Sample(timestampMs: timestampMs, devices: deviceSamples)
}

// MARK: - Main

func printUsage() {
    fputs("Usage: gpu-monitor [--period <ms>] [-n <count>]\n", stderr)
    fputs("  --period <ms>  Sampling period in milliseconds (default: 1000)\n", stderr)
    fputs("  -n <count>     Number of samples to collect, 0 for indefinite (default: 0)\n", stderr)
    fputs("\nOutputs JSONL to stdout with GPU memory and utilization.\n", stderr)
}

// Parse arguments
var periodMs: UInt32 = 1000
var maxSamples: UInt64 = 0

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--period", "-p":
        guard !args.isEmpty, let value = UInt32(args.removeFirst()) else {
            fputs("Error: --period requires a numeric value\n", stderr)
            exit(1)
        }
        periodMs = value
    case "-n":
        guard !args.isEmpty, let value = UInt64(args.removeFirst()) else {
            fputs("Error: -n requires a numeric value\n", stderr)
            exit(1)
        }
        maxSamples = value
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        fputs("Unknown argument: \(arg)\n", stderr)
        printUsage()
        exit(1)
    }
}

// Discover devices once at startup
let accelerators = getAccelerators()
let pciDevices = getPCIDevices()

var deviceInfos: [DeviceInfo] = []
var remainingPCIDevices = pciDevices

for acc in accelerators {
    guard let pciIdx = remainingPCIDevices.firstIndex(where: { devicesMatch(accelerator: acc, pciDevice: $0) }) else {
        continue
    }
    let pciDevice = remainingPCIDevices.remove(at: pciIdx)
    deviceInfos.append(DeviceInfo(index: deviceInfos.count, accelerator: acc, pciDevice: pciDevice))
}

if deviceInfos.isEmpty {
    fputs("No GPU devices found\n", stderr)
    exit(1)
}

fputs("Monitoring \(deviceInfos.count) device(s) every \(periodMs)ms\n", stderr)

// Setup JSON encoder
let encoder = JSONEncoder()
encoder.outputFormatting = .sortedKeys

// Sampling loop using mach_wait_until with absolute time anchoring
var timebaseInfo = mach_timebase_info_data_t()
mach_timebase_info(&timebaseInfo)

// Convert period to mach absolute time units
let periodNs: UInt64 = UInt64(periodMs) * 1_000_000
let periodMach: UInt64 = periodNs * UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)

// Anchor point for drift-free timing
let startTime = mach_absolute_time()
var iteration: UInt64 = 0

while maxSamples == 0 || iteration < maxSamples {
    let sample = sampleDevices(deviceInfos: deviceInfos)
    if let data = try? encoder.encode(sample),
       let json = String(data: data, encoding: .utf8) {
        print(json)
        fflush(stdout)
    }

    iteration += 1
    if maxSamples > 0 && iteration >= maxSamples {
        break
    }

    // Wait until absolute target time (prevents cumulative drift)
    let targetWake = startTime + iteration * periodMach
    mach_wait_until(targetWake)
}
