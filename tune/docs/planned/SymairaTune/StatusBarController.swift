@preconcurrency import AppKit
import SymTuneCore

/// Manages the menu-bar status item: icon, dropdown menu, and report display.
///
/// Each menu item triggers a read from `TuneController` and displays the result
/// inline in a submenu. No windows — everything stays in the menu bar.
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let controller = TuneController()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupMenu()
        configureButton()
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "SymairaTune") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "ST"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // -- Sensors --
        let sensorsItem = NSMenuItem(title: "Sensors", action: #selector(showSensors), keyEquivalent: "")
        sensorsItem.target = self
        sensorsItem.isEnabled = true
        menu.addItem(sensorsItem)

        // -- Battery --
        let batteryItem = NSMenuItem(title: "Battery", action: #selector(showBattery), keyEquivalent: "")
        batteryItem.target = self
        batteryItem.isEnabled = true
        menu.addItem(batteryItem)

        // -- Displays --
        let displaysItem = NSMenuItem(title: "Displays", action: #selector(showDisplays), keyEquivalent: "")
        displaysItem.target = self
        displaysItem.isEnabled = true
        menu.addItem(displaysItem)

        menu.addItem(.separator())

        // -- Version --
        let versionItem = NSMenuItem(title: "symtune v\(TuneVersion.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        menu.addItem(.separator())

        // -- Quit --
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func showSensors() {
        let report = controller.sensors_report()
        let submenu = NSMenu()

        submenu.addItem(NSMenuItem(
            title: "Thermal: \(report.thermalPressure)",
            action: nil, keyEquivalent: ""
        ))

        if !report.temperatures.isEmpty {
            submenu.addItem(.separator())
            for reading in report.temperatures {
                submenu.addItem(NSMenuItem(
                    title: "\(reading.label): \(String(format: "%.1f", reading.celsius))°C",
                    action: nil, keyEquivalent: ""
                ))
            }
        }

        if !report.fans.isEmpty {
            submenu.addItem(.separator())
            for fan in report.fans {
                submenu.addItem(NSMenuItem(
                    title: "\(fan.label): \(fan.rpm) RPM",
                    action: nil, keyEquivalent: ""
                ))
            }
        }

        if !report.notes.isEmpty {
            submenu.addItem(.separator())
            for note in report.notes {
                let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        statusItem.menu = submenu
        statusItem.button?.performClick(nil)
        // Restore the main menu after the submenu is dismissed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupMenu()
        }
    }

    @objc private func showBattery() {
        let report = controller.batteryReport()
        let submenu = NSMenu()

        if report.present {
            submenu.addItem(NSMenuItem(
                title: "Charge: \(report.currentCapacityPercent.map { "\($0)%" } ?? "—")",
                action: nil, keyEquivalent: ""
            ))
            submenu.addItem(NSMenuItem(
                title: "Health: \(report.healthPercent.map { "\($0)%" } ?? "—")",
                action: nil, keyEquivalent: ""
            ))
            submenu.addItem(NSMenuItem(
                title: "Cycles: \(report.cycleCount.map { "\($0)" } ?? "—")",
                action: nil, keyEquivalent: ""
            ))
            submenu.addItem(NSMenuItem(
                title: "Temp: \(report.temperatureCelsius.map { String(format: "%.1f°C", $0) } ?? "—")",
                action: nil, keyEquivalent: ""
            ))
            submenu.addItem(NSMenuItem(
                title: report.charging == true ? "Charging" : "On Battery",
                action: nil, keyEquivalent: ""
            ))
        } else {
            submenu.addItem(NSMenuItem(title: "No battery detected", action: nil, keyEquivalent: ""))
        }

        if !report.notes.isEmpty {
            submenu.addItem(.separator())
            for note in report.notes {
                let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        statusItem.menu = submenu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupMenu()
        }
    }

    @objc private func showDisplays() {
        let report = controller.displaysReport()
        let submenu = NSMenu()

        if report.displays.isEmpty {
            submenu.addItem(NSMenuItem(title: "No displays found", action: nil, keyEquivalent: ""))
        } else {
            for display in report.displays {
                let label = display.isBuiltin == true ? "Built-in" : "External"
                let edrStatus = display.edrCapable ? "EDR \(String(format: "%.1f", display.maxEDRHeadroom))x" : "no EDR"
                submenu.addItem(NSMenuItem(
                    title: "\(display.name) (\(label)) — \(edrStatus)",
                    action: nil, keyEquivalent: ""
                ))
            }
        }

        if !report.notes.isEmpty {
            submenu.addItem(.separator())
            for note in report.notes {
                let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        statusItem.menu = submenu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupMenu()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
