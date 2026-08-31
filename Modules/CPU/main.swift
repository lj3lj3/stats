//
//  main.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 09/04/2020.
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import WidgetKit

public struct CPU_Load: Codable, RemoteType {
    public var totalUsage: Double = 0
    var usagePerCore: [Double] = []
    var usageECores: Double? = nil
    var usagePCores: Double? = nil
    var usageSCores: Double? = nil
    
    var systemLoad: Double = 0
    var userLoad: Double = 0
    var idleLoad: Double = 0
    
    public func remote() -> Data? {
        var string = "1,1,\(self.totalUsage),\(self.usagePerCore.count),"
        for c in self.usagePerCore {
            string += "\(c),"
        }
        string += "$"
        return string.data(using: .utf8)
    }
}

public struct CPU_Frequency: Codable {
    var value: Double? = nil
    var eCore: Double? = nil
    var pCore: Double? = nil
    var sCore: Double? = nil
}

public struct CPU_Limit: Codable {
    var scheduler: Int = 0
    var cpus: Int = 0
    var speed: Int = 0
}

public struct CPU_AverageLoad: Codable, RemoteType {
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    
    public func remote() -> Data? {
        let string = "1,1,\(self.load1),\(self.load5),\(self.load15)$"
        return string.data(using: .utf8)
    }
}

public class CPU: Module {
    private let popupView: Popup
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private let previewView: Preview
    
    private var loadReader: LoadReader? = nil
    private var processReader: ProcessReader? = nil
    private var temperatureReader: TemperatureReader? = nil
    private var frequencyReader: FrequencyReader? = nil
    private var limitReader: LimitReader? = nil
    private var averageLoadReader: AverageLoadReader? = nil
    
    private var usagePerCoreState: Bool {
        Store.shared.bool(key: "\(self.config.name)_usagePerCore", defaultValue: false)
    }
    private var splitValueState: Bool {
        Store.shared.bool(key: "\(self.config.name)_splitValue", defaultValue: false)
    }
    private var groupByClustersState: Bool {
        Store.shared.bool(key: "\(self.config.name)_clustersGroup", defaultValue: false)
    }
    // 曲线 widget 的 top app 标注开关，决定进程采集是否常驻运行
    // key 必须与 LineChart 侧的 "\(title)_\(type.rawValue)_topApp" 完全一致，故直接引用 rawValue 避免手写字符串不一致
    private var topAppState: Bool {
        Store.shared.bool(key: "\(self.config.name)_\(widget_t.lineChart.rawValue)_topApp", defaultValue: false)
    }
    // 基类的 log 为 private，此处单独取一份同名 category 的日志句柄
    private var log: NextLog {
        NextLog.shared.copy(category: self.config.name)
    }
    private var systemColor: NSColor {
        let color = SColor.secondRed
        let key = Store.shared.string(key: "\(self.config.name)_systemColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var userColor: NSColor {
        let color = SColor.secondBlue
        let key = Store.shared.string(key: "\(self.config.name)_userColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    private var eCoresColor: NSColor {
        let color = SColor.teal
        let key = Store.shared.string(key: "\(self.config.name)_eCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var pCoresColor: NSColor {
        let color = SColor.indigo
        let key = Store.shared.string(key: "\(self.config.name)_pCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var sCoresColor: NSColor {
        let color = SColor.orange
        let key = Store.shared.string(key: "\(self.config.name)_sCoresColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        self.settingsView = Settings(.CPU)
        self.popupView = Popup(.CPU)
        self.portalView = Portal(.CPU, height: 120)
        self.notificationsView = Notifications(.CPU)
        self.previewView = Preview(.CPU)
        
        super.init(
            moduleType: .CPU,
            popup: self.popupView,
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: self.previewView
        )
        guard self.available else { return }
        
        self.loadReader = LoadReader(.CPU) { [weak self] value in
            self?.loadCallback(value)
        }
        self.processReader = ProcessReader(.CPU) { [weak self] value in
            self?.popupView.processCallback(value)
            self?.topAppCallback(value)
        }
        self.averageLoadReader = AverageLoadReader(.CPU, popup: true) { [weak self] value in
            self?.popupView.averageCallback(value)
            self?.previewView.averageCallback(value)
        }
        self.temperatureReader = TemperatureReader(.CPU, popup: true) { [weak self] value in
            self?.popupView.temperatureCallback(value)
        }
        
        #if arch(x86_64)
        self.limitReader = LimitReader(.CPU, popup: true) { [weak self] value in
            self?.popupView.limitCallback(value)
        }
        #else
        self.frequencyReader = FrequencyReader(.CPU) { [weak self] value in
            self?.popupView.frequencyCallback(value)
            self?.previewView.frequencyCallback(value)
        }
        #endif
        
        self.settingsView.callback = { [weak self] in
            self?.loadReader?.read()
        }
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            guard let self else { return }
            self.popupView.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.processReader?.read()
            }
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.loadReader?.setInterval(value)
        }
        self.settingsView.setTopInterval = { [weak self] value in
            self?.processReader?.setInterval(value)
        }
        
        self.setReaders([
            self.loadReader,
            self.processReader,
            self.temperatureReader,
            self.frequencyReader,
            self.limitReader,
            self.averageLoadReader
        ])
        
        self.syncTopAppReaderState()
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.listenForTopAppToggle), name: .toggleTopApp, object: nil)
    }
    
    // top app 开关与进程采集联动：开启时常驻轮询，关闭时退回仅在面板打开时采集
    private func syncTopAppReaderState() {
        guard let reader = self.processReader else { return }
        guard self.topAppState else {
            reader.popup = true
            reader.pause()
            // 关闭开关时重置采集计数，重新开启后从第一轮开始计数
            self.topAppCalcQueue.sync { self.topAppCalcCount = 0 }
            return
        }
        reader.popup = false
        // 先 start 使 reader 进入 active 状态，setInterval 内部仅在 active 时才重建定时器
        reader.start()
        let interval = Store.shared.int(key: "\(self.config.name)_updateTopInterval", defaultValue: 2)
        reader.setInterval(interval)
        debug("top app enabled, process reader started with \(interval)s interval", log: self.log)
    }
    
    @objc private func listenForTopAppToggle(_ notification: Notification) {
        guard notification.userInfo?["module"] as? String == self.config.name else { return }
        self.syncTopAppReaderState()
    }
    
    // 采集计算次数：每 topAppCalcStride 次采集才评估一次是否需要从右侧滑入
    private var topAppCalcCount: Int = 0
    // 每隔多少次采集计算执行一次滑入判断
    // 取 5：采集间隔 2s × 5 = 10s，与 widget 侧最小滑入间隔对齐，评估粒度恰好命中，不会退化成 12s
    private let topAppCalcStride: Int = 5
    // 保护采集计数的串行队列，Reader 回调可能来自非主线程
    private let topAppCalcQueue = DispatchQueue(label: "eu.exelban.Stats.CPU.TopAppCalc")
    
    // 把占用最高的进程分发到曲线 widget，未开启标注时不下发以免无谓重绘
    private func topAppCallback(_ list: [TopProcess]?) {
        guard self.topAppState, let process = list?.first else { return }
        // 累计采集次数，未达步长则跳过本轮判断
        let reached = self.topAppCalcQueue.sync { () -> Bool in
            self.topAppCalcCount += 1
            return self.topAppCalcCount % self.topAppCalcStride == 0
        }
        guard reached else { return }
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            if let widget = w.item as? LineChart {
                widget.setTopApp(process)
            }
        }
    }
    
    private func loadCallback(_ raw: CPU_Load?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView.loadCallback(value)
        self.portalView.callback(value)
        self.notificationsView.loadCallback(value)
        self.previewView.loadCallback(value)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { [self] (w: SWidget) in
            switch w.item {
            case let widget as Mini: widget.setValue(value.totalUsage)
            case let widget as LineChart: widget.setValue(value.totalUsage)
            case let widget as BarChart:
                var val: [[ColorValue]] = [[ColorValue(value.totalUsage)]]
                let cores = SystemKit.shared.device.info.cpu?.cores ?? []
                
                if self.usagePerCoreState {
                    if widget.colorState == .cluster {
                        val = []
                        for (i, v) in value.usagePerCore.enumerated() {
                            let core = cores.first(where: {$0.id == i })
                            let color = core?.type == .efficiency ? self.eCoresColor : core?.type == .super ? self.sCoresColor : self.pCoresColor
                            val.append([ColorValue(v, color: color)])
                        }
                    } else {
                        val = value.usagePerCore.map({ [ColorValue($0)] })
                    }
                } else if self.splitValueState {
                    val = [[
                        ColorValue(value.systemLoad, color: self.systemColor),
                        ColorValue(value.userLoad, color: self.userColor)
                    ]]
                } else if self.groupByClustersState {
                    var clusters: [[ColorValue]] = []
                    var clustersPlain: [[ColorValue]] = []
                    
                    if let e = value.usageECores {
                        clusters.append([ColorValue(e, color: self.eCoresColor)])
                        clustersPlain.append([ColorValue(e)])
                    }
                    if let p = value.usagePCores {
                        clusters.append([ColorValue(p, color: self.pCoresColor)])
                        clustersPlain.append([ColorValue(p)])
                    }
                    if let s = value.usageSCores {
                        clusters.append([ColorValue(s, color: self.sCoresColor)])
                        clustersPlain.append([ColorValue(s)])
                    }
                    
                    if !clusters.isEmpty {
                        val = widget.colorState == .cluster ? clusters : clustersPlain
                    }
                }
                widget.setValue(val)
            case let widget as PieChart:
                widget.setValue([
                    ColorValue(value.systemLoad, color: self.systemColor),
                    ColorValue(value.userLoad, color: self.userColor)
                ])
            case let widget as Tachometer:
                widget.setValue([
                    ColorValue(value.systemLoad, color: self.systemColor),
                    ColorValue(value.userLoad, color: self.userColor)
                ])
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            if isWidgetActive(self.userDefaults, [CPU_entry.kind, "UnitedWidget"]), let blobData = try? JSONEncoder().encode(value) {
                self.userDefaults?.set(blobData, forKey: "CPU@LoadReader")
            }
            WidgetCenter.shared.reloadTimelines(ofKind: CPU_entry.kind)
            WidgetCenter.shared.reloadTimelines(ofKind: "UnitedWidget")
        }
    }
}
