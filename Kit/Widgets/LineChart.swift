//
//  Chart.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 18/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public class LineChart: WidgetWrapper {
    private var labelState: Bool = false
    private var boxState: Bool = true
    private var frameState: Bool = false
    private var valueState: Bool = false
    private var valueColorState: Bool = false
    private var colorState: SColor = .systemAccent
    private var historyCount: Int = 60
    private var scaleState: Scale = .none
    // topApp 开关：开启后曲线峰值位置绘制占用最高 app 的图标
    private var topAppState: Bool = false
    // 图标边长
    private let topAppIconSize: CGFloat = 12
    // 展示阈值：CPU 总占用（0~1）低于该值时不滑入图标
    private var topAppThreshold: Double = 0.3
    // 阈值下拉选项，值为百分比字符串，便于本地化展示
    private var topAppThresholdNumbers: [KeyValue_p] = [
        KeyValue_t(key: "0.1", value: "10%"),
        KeyValue_t(key: "0.2", value: "20%"),
        KeyValue_t(key: "0.3", value: "30%"),
        KeyValue_t(key: "0.5", value: "50%"),
        KeyValue_t(key: "0.7", value: "70%"),
        KeyValue_t(key: "0.9", value: "90%")
    ]
    // 日志 category 用 widget 标题（CPU），WidgetWrapper 未提供 log，此处直接构造
    private var log: NextLog { NextLog.shared.copy(category: self.title) }
    
    // 已绘制的标注：记录进程、锚定的曲线点位索引及锚定时的数值，索引随曲线前进递减
    // 不在曲线上的进程可立即绘制，滚出左边界后再次登顶同样立即从右侧进入
    private var topAppMarks: [(process: TopProcess, index: Int, value: Double)] = []
    // 每个进程上次绘制时间戳，用于强制同一图标出现间隔 ≥30s 冷却
    private var topAppLastDrawTime: [Int: Date] = [:]
    // 同一图标两次滑入的最小间隔（秒），防止同一 app 图标频繁重复出现
    private let topAppCooldownSeconds: TimeInterval = 30
    // 上一个图标滑入的时间，用于限制任意两个图标之间的最小间隔
    private var topAppLastSpawnTime: Date?
    // 任意两个图标滑入的最小间隔（秒），决定图表内图标总数上限
    private let topAppMinSpawnInterval: TimeInterval = 10
    
    private var chart: LineChartView = LineChartView(frame: NSRect(
        x: 0,
        y: 0,
        width: 32,
        height: Constants.Widget.height - (2*Constants.Widget.margin.y)
    ), num: 60, animation: false)
    private var colors: [SColor] = SColor.allCases.filter({ $0 != SColor.cluster })
    private var _value: Double = 0
    private var _pressureLevel: RAMPressure = .normal
    
    private var historyNumbers: [KeyValue_p] = [
        KeyValue_t(key: "30", value: "30"),
        KeyValue_t(key: "60", value: "60"),
        KeyValue_t(key: "90", value: "90"),
        KeyValue_t(key: "120", value: "120")
    ]
    // 图表宽度倍率：作用于基准宽度，1x 为原始尺寸
    private var widthScale: Int = 1
    private var widthScaleNumbers: [KeyValue_p] = [
        KeyValue_t(key: "1", value: "1x"),
        KeyValue_t(key: "2", value: "2x"),
        KeyValue_t(key: "3", value: "3x"),
        KeyValue_t(key: "5", value: "5x")
    ]
    private var width: CGFloat {
        get {
            let base: CGFloat
            switch self.historyCount {
            case 30:
                base = 24
            case 60:
                base = 32
            case 90:
                base = 42
            case 120:
                base = 52
            default:
                base = 32
            }
            return base * CGFloat(self.widthScale)
        }
    }
    // 有效点数：随宽度倍率同比放大，使每格位移（xStep）保持恒定，
    // 从而保证任意倍率下曲线与图标的横向移动速度与 1x 一致
    private var effectiveHistoryCount: Int {
        max(self.historyCount * self.widthScale, 2)
    }
    
    private var boxSettingsView: NSSwitch? = nil
    private var frameSettingsView: NSSwitch? = nil
    
    public var NSLabelCharts: [NSAttributedString] = []
    
    public init(title: String, config: NSDictionary?, preview: Bool = false) {
        var widgetTitle: String = title
        if config != nil {
            if let titleFromConfig = config!["Title"] as? String {
                widgetTitle = titleFromConfig
            }
            if let label = config!["Label"] as? Bool {
                self.labelState = label
            }
            if let box = config!["Box"] as? Bool {
                self.boxState = box
            }
            if let value = config!["Value"] as? Bool {
                self.valueState = value
            }
            if let unsupportedColors = config!["Unsupported colors"] as? [String] {
                self.colors = self.colors.filter{ !unsupportedColors.contains($0.key) }
            }
            if let color = config!["Color"] as? String {
                if let defaultColor = colors.first(where: { $0.key == color }) {
                    self.colorState = defaultColor
                }
            }
        }
        
        super.init(.lineChart, title: widgetTitle, frame: CGRect(
            x: Constants.Widget.margin.x,
            y: Constants.Widget.margin.y,
            width: 32 + (Constants.Widget.margin.x*2),
            height: Constants.Widget.height - (2*Constants.Widget.margin.y)
        ))
        
        self.canDrawConcurrently = true
        
        if !preview {
            self.boxState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_box", defaultValue: self.boxState)
            self.frameState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_frame", defaultValue: self.frameState)
            self.valueState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_value", defaultValue: self.valueState)
            self.labelState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_label", defaultValue: self.labelState)
            self.valueColorState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_valueColor", defaultValue: self.valueColorState)
            self.colorState = SColor.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_color", defaultValue: self.colorState.key))
            self.historyCount = Store.shared.int(key: "\(self.title)_\(self.type.rawValue)_historyCount", defaultValue: self.historyCount)
            self.scaleState = Scale.fromString(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_scale", defaultValue: self.scaleState.key))
            self.topAppState = Store.shared.bool(key: "\(self.title)_\(self.type.rawValue)_topApp", defaultValue: self.topAppState)
            self.widthScale = Store.shared.int(key: "\(self.title)_\(self.type.rawValue)_widthScale", defaultValue: self.widthScale)
            // Store 无 double 存取，阈值以字符串保存后转换，失败时保留默认值
            if let threshold = Double(Store.shared.string(key: "\(self.title)_\(self.type.rawValue)_topAppThreshold", defaultValue: "\(self.topAppThreshold)")) {
                self.topAppThreshold = threshold
            }
            
            self.chart.setScale(self.scaleState)
            self.chart.reinit(self.effectiveHistoryCount)
            // 初始化索引换算基准，供后续倍率切换时按比例换算已有标注位置
            self.rescaleBaseline = self.effectiveHistoryCount
        }
        
        if self.labelState {
            self.setFrameSize(NSSize(width: Constants.Widget.width + 6 + (Constants.Widget.margin.x*2), height: self.frame.size.height))
        }
        
        if preview {
            var list: [DoubleValue] = []
            for _ in 0..<16 {
                list.append(DoubleValue(Double.random(in: 0..<1)))
            }
            self.chart.setPoints(list)
            self._value = 0.38
        }
        
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let stringAttributes = [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 7, weight: .regular),
            NSAttributedString.Key.foregroundColor: NSColor.textColor,
            NSAttributedString.Key.paragraphStyle: style
        ]
        
        for char in String(self.title.prefix(3)).uppercased().reversed() {
            let str = NSAttributedString.init(string: "\(char)", attributes: stringAttributes)
            self.NSLabelCharts.append(str)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        var value: Double = 0
        var pressureLevel: RAMPressure = .normal
        self.queue.sync {
            value = self._value
            pressureLevel = self._pressureLevel
        }
        
        var width = self.width + (Constants.Widget.margin.x*2)
        var x: CGFloat = 0
        let lineWidth = 1 / (NSScreen.main?.backingScaleFactor ?? 1)
        let offset = lineWidth / 2
        var boxSize: CGSize = CGSize(width: self.width - (Constants.Widget.margin.x*2), height: self.frame.size.height)
        
        var color: NSColor = .controlAccentColor
        switch self.colorState {
        case .systemAccent: color = .controlAccentColor
        case .utilization: color = value.usageColor()
        case .pressure: color = pressureLevel.pressureColor()
        case .monochrome:
            if self.boxState {
                color = (isDarkMode ? NSColor.black : NSColor.white)
            } else {
                color = (isDarkMode ? NSColor.white : NSColor.black)
            }
        default: color = self.colorState.additional as? NSColor ?? .controlAccentColor
        }
        
        if self.labelState {
            let letterHeight = self.frame.height / 3
            let letterWidth: CGFloat = 6.0
            
            var yMargin: CGFloat = 0
            for char in self.NSLabelCharts {
                let rect = CGRect(x: x, y: yMargin, width: letterWidth, height: letterHeight)
                char.draw(with: rect)
                yMargin += letterHeight
            }
            
            width += letterWidth + Constants.Widget.spacing
            x = letterWidth + Constants.Widget.spacing
        }
        
        if self.valueState {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            
            var valueColor = isDarkMode ? NSColor.white : NSColor.black
            if self.valueColorState {
                valueColor = color
            }
            
            let stringAttributes = [
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 8, weight: .regular),
                NSAttributedString.Key.foregroundColor: valueColor,
                NSAttributedString.Key.paragraphStyle: style
            ]
            
            let rect = CGRect(x: x+2, y: boxSize.height-7, width: boxSize.width - 2, height: 7)
            let str = NSAttributedString.init(string: "\(Int((value.rounded(toPlaces: 2)) * 100))%", attributes: stringAttributes)
            str.draw(with: rect)
            
            boxSize.height = offset == 0.5 ? 10 : 9
        }
        
        let box = NSBezierPath(roundedRect: NSRect(
            x: x+offset,
            y: offset,
            width: self.width - offset*2,
            height: boxSize.height - (offset*2)
        ), xRadius: 2, yRadius: 2)
        
        if self.boxState {
            (isDarkMode ? NSColor.white : NSColor.black).set()
            box.stroke()
            box.fill()
            self.chart.setTransparent(false)
        } else if self.frameState {
            self.chart.setTransparent(true)
        } else {
            self.chart.setTransparent(true)
        }
        
        context.saveGState()
        context.translateBy(x: x+offset+lineWidth, y: offset)
        
        let chartSize = NSSize(
            width: box.bounds.width - (offset*2+lineWidth),
            height: box.bounds.height - offset
        )
        self.chart.setColor(color)
        self.chart.setFrameSize(chartSize)
        self.chart.draw(NSRect(origin: .zero, size: chartSize))
        
        if self.topAppState {
            self.drawTopAppMarks()
        }
        
        context.restoreGState()
        
        if self.boxState || self.frameState {
            (isDarkMode ? NSColor.white : NSColor.black).set()
            box.lineWidth = lineWidth
            box.stroke()
        }
        
        self.setWidth(width)
    }
    
    // 在曲线内各已确认标注的锚定位置绘制 app 图标，位置随曲线滚动左移
    // 此方法在 draw() 的 context.translateBy 之后调用，pointAt 与曲线绘制共享同一平移后坐标系
    private func drawTopAppMarks() {
        var marks: [(process: TopProcess, index: Int, value: Double)] = []
        self.queue.sync { marks = self.topAppMarks }
        guard !marks.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        for mark in marks {
            guard let point = self.chart.pointAt(index: mark.index, value: mark.value) else { continue }
            // 图标中心对齐锚定曲线点：图标骑在曲线上，高度随负载起伏
            // 不做 max(...,0) 截断：图表高度仅十几 pt，截断会把图标压在底部，
            // 溢出部分交由下方 clip 自然裁切（低负载时图标下半部可见，视觉上从底部露出）
            let iconRect = NSRect(
                x: point.x - self.topAppIconSize / 2,
                y: point.y - self.topAppIconSize / 2,
                width: self.topAppIconSize,
                height: self.topAppIconSize
            )
            // 裁剪到曲线可视区域内，滚出左边缘时图标被逐步裁掉而非整体消失
            context.saveGState()
            context.clip(to: CGRect(origin: .zero, size: self.chart.frame.size))
            mark.process.icon.draw(in: iconRect)
            context.restoreGState()
        }
    }
    
    // 清空已绘制标注、各进程冷却记录及全局滑入计时
    private func resetTopAppMarks() {
        self.queue.sync {
            self.topAppMarks.removeAll()
            self.topAppLastDrawTime.removeAll()
            self.topAppLastSpawnTime = nil
        }
    }
    
    // 曲线每前进一格，标注锚定索引同步左移；图标完全滚出左边界后才丢弃
    private func shiftTopAppMarks() {
        let step = self.chart.xStep()
        guard step > 0 else { return }
        // 图标右边缘仍在可视区内则保留，索引可为负值以让图标平滑滚出
        let minIndex = Int((-self.topAppIconSize / 2) / step) - 1
        self.queue.sync {
            self.topAppMarks = self.topAppMarks.compactMap { mark in
                let newIndex = mark.index - 1
                return newIndex >= minIndex ? (process: mark.process, index: newIndex, value: mark.value) : nil
            }
        }
    }
    
    // 记录当前占用最高的进程：从曲线右侧边缘进入，随曲线左移滚出；同 pid 需满足冷却
    // 注意：此方法仅记录待绘制进程，实际添加 mark 和绘制由 setValue 在主线程同步完成，
    // 避免 setTopApp 异步 main.async 与 setValue 的 main.async 之间的时序竞争导致图标闪现
    // pending 携带阈值通过时刻的曲线值：LoadReader（1s）可能在消费前更新 _value，
    // 用消费时刻的值会导致图标高度偏离登顶时刻（甚至趴底）
    private var topAppPending: (process: TopProcess, value: Double)?
    
    public func setTopApp(_ newValue: TopProcess?) {
        guard let process = newValue else { return }
        // 阈值检查：CPU 总占用未达阈值时不滑入图标，_value 为 0~1 的总占用
        let usage = self.queue.sync { self._value }
        guard usage >= self.topAppThreshold else { return }
        // 已在曲线上的进程不重复添加
        let alreadyMarked = self.queue.sync { self.topAppMarks.contains(where: { $0.process.pid == process.pid }) }
        guard !alreadyMarked else { return }
        // 同一图标冷却期检查：距上次绘制不足 30s 则跳过
        let cooldownDue: Bool = self.queue.sync {
            if let last = self.topAppLastDrawTime[process.pid] {
                return Date().timeIntervalSince(last) < self.topAppCooldownSeconds
            }
            return false
        }
        guard !cooldownDue else { return }
        // 全局最小滑入间隔检查
        let now = Date()
        let tooSoon: Bool = self.queue.sync {
            guard let last = self.topAppLastSpawnTime else { return false }
            return now.timeIntervalSince(last) < self.topAppMinSpawnInterval
        }
        guard !tooSoon else { return }
        // 记录待绘制进程及其时的曲线值，由 setValue 在主线程同步消费，消除异步时序差
        self.queue.sync { self.topAppPending = (process: process, value: usage) }
    }
    
    // 倍率切换后点数改变，按新旧点数比例换算已有标注的锚定索引，保持其在图表中的相对位置
    private func rescaleTopAppMarks() {
        let newCount = self.effectiveHistoryCount
        self.queue.sync {
            guard !self.topAppMarks.isEmpty else { return }
            self.topAppMarks = self.topAppMarks.map { mark in
                (process: mark.process, index: Int(round(Double(mark.index) * Double(newCount - 1) / Double(max(self.rescaleBaseline - 1, 1)))), value: mark.value)
            }
        }
        self.rescaleBaseline = newCount
    }
    
    // rescaleTopAppMarks 使用的旧点数基准
    private var rescaleBaseline: Int = 60
    
    // 在 setValue 的主线程回调中同步调用：先 shift 已有标注，再消费 pending 进程添加新标注
    private func consumePendingTopApp() {
        let pending = self.queue.sync { () -> (process: TopProcess, value: Double)? in
            guard let p = self.topAppPending else { return nil }
            self.topAppPending = nil
            return p
        }
        guard let (process, value) = pending else { return }
        // 入场锚点：图标整体位于右边界之外，从完全不可见开始随曲线左移露出
        guard let rightIndex = self.chart.spawnIndex(iconOffset: self.topAppIconSize / 2) else { return }
        let now = Date()
        
        let added: Bool = self.queue.sync {
            // 二次校验：pending 记录期间进程可能已被其他路径添加
            guard !self.topAppMarks.contains(where: { $0.process.pid == process.pid }) else { return false }
            // 图标高度使用 pending 携带的曲线值（阈值通过时刻的 _value）：
            // 消费时刻的 _value 可能已被 LoadReader 更新（1s 相位差），CPU 突降时图标会趴底
            self.topAppMarks.append((process: process, index: rightIndex, value: value))
            self.topAppLastDrawTime[process.pid] = now
            self.topAppLastSpawnTime = now
            return true
        }
        guard added else {
            debug("top app mark skipped, pid=\(process.pid) name=\(process.name) already marked", log: self.log)
            return
        }
        info("top app mark added, pid=\(process.pid) name=\(process.name) index=\(rightIndex) value=\(String(format: "%.2f", value)) total=\(self.topAppMarks.count) threshold=\(self.topAppThreshold)", log: self.log)
    }
    
    public func setValue(_ newValue: Double) {
        self.queue.sync {
            self._value = newValue
        }
        self.chart.addValue(newValue)
        DispatchQueue.main.async(execute: { [weak self] in
            guard let self else { return }
            // 曲线前进一格，同步已有标注的锚定索引；需在主线程读取 NSView 几何
            if self.topAppState {
                self.shiftTopAppMarks()
                // 同步消费待绘制进程：在 shift 之后、display 之前添加新标注到最右端，
                // 确保图标从右边缘开始，避免 setTopApp 异步 main.async 与此处的时序竞争
                self.consumePendingTopApp()
            }
            self.needsDisplay = true
        })
    }
    
    public func setPressure(_ newPressureLevel: RAMPressure) {
        let updated = self.queue.sync { () -> Bool in
            guard self._pressureLevel != newPressureLevel else { return false }
            self._pressureLevel = newPressureLevel
            return true
        }
        guard updated else { return }
        DispatchQueue.main.async(execute: {
            self.needsDisplay = true
        })
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView {
        let view = SettingsContainerView()
        
        let box = switchView(
            action: #selector(self.toggleBox),
            state: self.boxState
        )
        self.boxSettingsView = box
        let frame = switchView(
            action: #selector(self.toggleFrame),
            state: self.frameState
        )
        self.frameSettingsView = frame
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Label"), component: switchView(
                action: #selector(self.toggleLabel),
                state: self.labelState
            )),
            PreferencesRow(localizedString("Value"), component: switchView(
                action: #selector(self.toggleValue),
                state: self.valueState
            )),
            PreferencesRow(localizedString("Box"), component: box),
            PreferencesRow(localizedString("Frame"), component: frame),
            PreferencesRow(localizedString("Color"), component: colorSelectView(
                action: #selector(self.toggleColor),
                items: self.colors,
                selected: self.colorState.key
            )),
            PreferencesRow(localizedString("Colorize value"), component: switchView(
                action: #selector(self.toggleValueColor),
                state: self.valueColorState
            )),
            PreferencesRow(localizedString("Number of reads in the chart"), component: selectView(
                action: #selector(self.toggleHistoryCount),
                items: self.historyNumbers,
                selected: "\(self.historyCount)"
            )),
            PreferencesRow(localizedString("Chart width"), component: selectView(
                action: #selector(self.toggleWidthScale),
                items: self.widthScaleNumbers,
                selected: "\(self.widthScale)"
            )),
            PreferencesRow(localizedString("Scaling"), component: selectView(
                action: #selector(self.toggleScale),
                items: Scale.allCases.filter({ $0 != .fixed }),
                selected: self.scaleState.key
            )),
            PreferencesRow(localizedString("Show top app"), component: switchView(
                action: #selector(self.toggleTopApp),
                state: self.topAppState
            )),
            PreferencesRow(localizedString("Top app threshold"), component: selectView(
                action: #selector(self.toggleTopAppThreshold),
                items: self.topAppThresholdNumbers,
                selected: "\(self.topAppThreshold)"
            ))
        ]))
        
        return view
    }
    
    @objc private func toggleLabel(_ sender: NSControl) {
        self.labelState = controlState(sender)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_label", value: self.labelState)
        self.display()
    }
    
    @objc private func toggleBox(_ sender: NSControl) {
        self.boxState = controlState(sender)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_box", value: self.boxState)
        
        if self.frameState {
            self.frameSettingsView?.state = .off
            self.frameState = false
            Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_frame", value: self.frameState)
        }
        
        self.display()
    }
    
    @objc private func toggleFrame(_ sender: NSControl) {
        self.frameState = controlState(sender)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_frame", value: self.frameState)
        
        if self.boxState {
            self.boxSettingsView?.state = .off
            self.boxState = false
            Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_box", value: self.boxState)
        }
        
        self.display()
    }
    
    @objc private func toggleValue(_ sender: NSControl) {
        self.valueState = controlState(sender)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_value", value: self.valueState)
        self.display()
    }
    
    @objc private func toggleColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.colorState = SColor.fromString(key, defaultValue: self.colorState)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_color", value: self.colorState.key)
        self.display()
    }
    
    @objc private func toggleValueColor(_ sender: NSControl) {
        self.valueColorState = controlState(sender)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_valueColor", value: self.valueColorState)
        self.display()
    }
    
    @objc private func toggleHistoryCount(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.historyCount = value
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_historyCount", value: value)
        self.rescaleTopAppMarks()
        self.chart.reinit(self.effectiveHistoryCount)
        self.display()
    }
    
    @objc private func toggleTopAppThreshold(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Double(key) else { return }
        self.topAppThreshold = value
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_topAppThreshold", value: key)
        // 阈值提高后，已入场的图标不追溯清理，自然随曲线滑出
        self.display()
    }
    
    @objc private func toggleWidthScale(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key), value >= 1 else { return }
        self.widthScale = value
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_widthScale", value: value)
        // 点数随宽度同比重建，保持每格位移恒定，使移动速度与倍率无关
        self.chart.reinit(self.effectiveHistoryCount)
        // 倍率变化后点距改变，已入场图标的锚定索引按新比例重新换算，避免位置跳变
        self.rescaleTopAppMarks()
        // 宽度变化后立即重绘，菜单栏宽度由 draw() 末尾 setWidth 自动跟随
        self.display()
    }

    @objc private func toggleScale(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let value = Scale.allCases.first(where: { $0.key == key }) else { return }
        self.scaleState = value
        self.chart.setScale(value)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_scale", value: key)
        self.display()
    }
    
    @objc private func toggleTopApp(_ sender: NSControl) {
        self.topAppState = controlState(sender)
        Store.shared.set(key: "\(self.title)_\(self.type.rawValue)_topApp", value: self.topAppState)
        if !self.topAppState {
            self.resetTopAppMarks()
        }
        // 通知模块侧联动进程采集的启停，避免开关关闭后仍在轮询
        NotificationCenter.default.post(name: .toggleTopApp, object: nil, userInfo: [
            "module": self.title,
            "state": self.topAppState
        ])
        self.display()
    }
    
}

