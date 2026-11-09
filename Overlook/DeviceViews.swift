import SwiftUI
import AppKit

// MARK: - The device chooser

/// What one row of the Connections panel's device menu says: the nickname, with the address after
/// it, or the address alone for a device without a nickname. The address is the one a plain
/// Connect uses.
struct DeviceMenuTitle: Equatable {
    let name: String
    /// Shown after the name, right-aligned; nil when the name is the address.
    let address: String?

    init(name: String, address: String?) {
        self.name = name
        self.address = address
    }

    init(_ device: KVMDevice) {
        if let nickname = device.nickname {
            self.init(name: nickname, address: device.address.label)
        } else {
            self.init(name: device.address.label, address: nil)
        }
    }

    static let nameFont = NSFont.menuFont(ofSize: 0)
    static var addressFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
    }

    /// The row as the menu draws it: the name, a tab, and the address in a monospaced secondary
    /// font, the tab stop right-aligned at `column` so the addresses line up on their right edge.
    func attributed(column: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: column)]
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: name,
            attributes: [.font: Self.nameFont, .paragraphStyle: paragraph]
        )
        if let address {
            text.append(NSAttributedString(
                string: "\t" + address,
                attributes: [
                    .font: Self.addressFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return text
    }

    /// Where the right-aligned tab stop goes for a set of rows: past the widest name, a gap, and
    /// the widest address.
    static func column(for titles: [DeviceMenuTitle], gap: CGFloat = 28) -> CGFloat {
        let nameWidth = titles.map { ($0.name as NSString).size(withAttributes: [.font: nameFont]).width }.max() ?? 0
        let addressWidth = titles.compactMap(\.address)
            .map { ($0 as NSString).size(withAttributes: [.font: addressFont]).width }
            .max() ?? 0
        return ceil(nameWidth + gap + addressWidth)
    }
}

/// The Connections panel's device menu: an AppKit pop-up button, because a SwiftUI `Picker` draws
/// its rows as plain text and the address has to sit right-aligned in its own font.
struct DevicePopUpButton: NSViewRepresentable {
    let devices: [KVMDevice]
    /// The entry chosen, by id; nil shows "Select Device".
    let selectedID: String?
    let onSelect: (KVMDevice?) -> Void

    static let placeholder = "Select Device"

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.chose(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Device")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        let titles = devices.map(DeviceMenuTitle.init)
        let signature = zip(devices, titles).map { "\($0.id)|\($1.name)|\($1.address ?? "")" }
        if signature != coordinator.signature {
            coordinator.signature = signature
            coordinator.devices = devices
            let column = DeviceMenuTitle.column(for: titles)
            button.removeAllItems()
            button.addItem(withTitle: Self.placeholder)
            for title in titles {
                let item = NSMenuItem(title: title.name, action: nil, keyEquivalent: "")
                item.attributedTitle = title.attributed(column: column)
                // Read by VoiceOver and by the menu's type-to-select.
                item.setAccessibilityLabel([title.name, title.address].compactMap { $0 }.joined(separator: ", "))
                button.menu?.addItem(item)
            }
        } else {
            coordinator.devices = devices
        }
        let index = selectedID.flatMap { id in devices.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        if button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var onSelect: (KVMDevice?) -> Void
        var devices: [KVMDevice] = []
        var signature: [String] = []

        init(onSelect: @escaping (KVMDevice?) -> Void) {
            self.onSelect = onSelect
        }

        @objc func chose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem - 1
            onSelect(devices.indices.contains(index) ? devices[index] : nil)
        }
    }
}
