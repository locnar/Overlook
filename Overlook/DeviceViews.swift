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

    /// Where the closed pop-up draws the selected row inside `frame`, its title area: the address
    /// against the right edge, as the open menu has it, and the name from the left edge up to
    /// `gap` short of the address (truncated there if it is longer).
    static func closedLayout(in frame: NSRect, addressWidth: CGFloat, gap: CGFloat = 12) -> (name: NSRect, address: NSRect) {
        let width = min(ceil(addressWidth), frame.width)
        let address = NSRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        let name = NSRect(x: frame.minX, y: frame.minY, width: max(0, address.minX - gap - frame.minX), height: frame.height)
        return (name, address)
    }
}

/// The device pop-up's cell. The open menu lays a row out with a right-aligned tab stop, but the
/// closed pop-up ignored it and drew the address straight after the name; this draws the selected
/// row itself, the address right-aligned in the menu's monospaced secondary style and on the
/// name's baseline. The placeholder, and a device shown by its address alone, are drawn as before.
final class DevicePopUpCell: NSPopUpButtonCell {
    /// The rows after the placeholder, as the button holds them.
    var titles: [DeviceMenuTitle] = []

    /// Room at the right of the closed pop-up for its arrows; the address ends just left of them.
    static let arrowsWidth: CGFloat = 26

    /// The selected row when it has an address to put on the right.
    private var selectedRow: DeviceMenuTitle? {
        let index = indexOfSelectedItem - 1
        guard titles.indices.contains(index), titles[index].address != nil else { return nil }
        return titles[index]
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard let row = selectedRow else {
            return super.drawTitle(title, withFrame: frame, in: controlView)
        }
        // `frame` is only as wide as the title the cell measured (name and address with the tab
        // read as a space); the row is laid out from its left edge to the arrows instead.
        let area = Self.titleArea(from: frame, bounds: controlView.bounds)
        draw(row, in: area, flipped: controlView.isFlipped)
        return area
    }

    /// From the left of the title the cell measured to just short of the arrows.
    static func titleArea(from frame: NSRect, bounds: NSRect) -> NSRect {
        let right = max(frame.maxX, bounds.maxX - arrowsWidth)
        return NSRect(x: frame.minX, y: frame.minY, width: right - frame.minX, height: frame.height)
    }

    private func draw(_ row: DeviceMenuTitle, in frame: NSRect, flipped: Bool) {
        let nameFont = font ?? DeviceMenuTitle.nameFont
        let addressFont = DeviceMenuTitle.addressFont
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(string: row.name, attributes: [
            .font: nameFont,
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: truncating,
        ])
        let address = NSAttributedString(string: row.address ?? "", attributes: [
            .font: addressFont,
            .foregroundColor: isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
        ])
        let layout = DeviceMenuTitle.closedLayout(in: frame, addressWidth: address.size().width)

        // The name's line centred in the frame, the address's on the same baseline. Offsets are
        // from the frame's top as it looks on screen.
        let nameHeight = ceil(nameFont.ascender - nameFont.descender + nameFont.leading)
        let addressHeight = ceil(addressFont.ascender - addressFont.descender + addressFont.leading)
        let nameTop = (frame.height - nameHeight) / 2
        let addressTop = nameTop + nameFont.ascender - addressFont.ascender
        func line(_ rect: NSRect, top: CGFloat, height: CGFloat) -> NSRect {
            let y = flipped ? rect.minY + top : rect.maxY - top - height
            return NSRect(x: rect.minX, y: y, width: rect.width, height: height)
        }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        name.draw(with: line(layout.name, top: nameTop, height: nameHeight), options: options)
        address.draw(with: line(layout.address, top: addressTop, height: addressHeight), options: options)
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

    func makeNSView(context: Context) -> DevicePopUpNSButton {
        let button = DevicePopUpNSButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.chose(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel("Device")
        return button
    }

    func updateNSView(_ button: DevicePopUpNSButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        let titles = devices.map(DeviceMenuTitle.init)
        let signature = zip(devices, titles).map { "\($0.id)|\($1.name)|\($1.address ?? "")" }
        if signature != coordinator.signature {
            coordinator.signature = signature
            coordinator.devices = devices
            button.removeAllItems()
            button.addItem(withTitle: Self.placeholder)
            for title in titles {
                let item = NSMenuItem(title: title.name, action: nil, keyEquivalent: "")
                // Read by VoiceOver and by the menu's type-to-select.
                item.setAccessibilityLabel([title.name, title.address].compactMap { $0 }.joined(separator: ", "))
                button.menu?.addItem(item)
            }
            button.titles = titles
        } else {
            coordinator.devices = devices
        }
        let index = selectedID.flatMap { id in devices.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        if button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    /// Lays the rows out again whenever its width changes, so the addresses sit against the
    /// right edge of the button and of its menu (which is as wide as the button).
    final class DevicePopUpNSButton: NSPopUpButton {
        override class var cellClass: AnyClass? {
            get { DevicePopUpCell.self }
            set {}
        }

        var titles: [DeviceMenuTitle] = [] {
            didSet {
                (cell as? DevicePopUpCell)?.titles = titles
                applyTitles(force: true)
            }
        }
        private var appliedColumn: CGFloat = -1

        /// Room left of the tab stop for the pop-up's arrows and the menu's checkmark column.
        static let trailingInset: CGFloat = 44

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            applyTitles(force: false)
        }

        private func applyTitles(force: Bool) {
            let column = max(DeviceMenuTitle.column(for: titles), floor(bounds.width - Self.trailingInset))
            guard force || column != appliedColumn else { return }
            appliedColumn = column
            for (index, title) in titles.enumerated() {
                item(at: index + 1)?.attributedTitle = title.attributed(column: column)
            }
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

// MARK: - Edit…

/// What the Edit… sheet holds while it is open: the name as typed, the address list, the row
/// selected in it, and the address being added. Save hands `result` to the catalog.
@MainActor
final class DeviceEditModel: ObservableObject {
    /// The nickname as typed; empty shows the address.
    @Published var name: String
    @Published private(set) var addresses: [DeviceAddress]
    @Published var selection: DeviceAddress?
    /// Whether the row for typing a new address is open (`+`).
    @Published private(set) var isAddingAddress = false
    @Published var newHost = ""
    @Published var newPort = ""
    /// Why the last address typed was refused.
    @Published private(set) var problem: String?

    let device: KVMDevice
    /// The saved device other than this one that has an address, if any.
    private let owner: (DeviceAddress) -> KVMDevice?

    static let namePrompt = "Leave empty to show the address"

    init(device: KVMDevice, owner: @escaping (DeviceAddress) -> KVMDevice? = { _ in nil }) {
        self.device = device
        self.owner = owner
        name = device.nickname ?? ""
        addresses = device.addresses
        selection = nil
    }

    /// `−` removes the selected address, never the last one.
    var canRemove: Bool {
        guard let selection else { return false }
        return addresses.count > 1 && addresses.contains(selection)
    }

    var canSave: Bool { !addresses.isEmpty && !isAddingAddress }

    /// What Save writes: the nickname (nil shows the address) and the addresses in order.
    var result: (nickname: String?, addresses: [DeviceAddress]) {
        (DeviceNaming.cleanNickname(name), addresses)
    }

    func beginAddingAddress() {
        isAddingAddress = true
        newHost = ""
        newPort = ""
        problem = nil
    }

    func cancelAddingAddress() {
        isAddingAddress = false
        newHost = ""
        newPort = ""
        problem = nil
    }

    /// Reads the typed address as Manual Connect does and adds it, selected. Refused with a
    /// reason when it does not read, is already listed, or belongs to another saved device.
    @discardableResult
    func addAddress() -> Bool {
        switch AddressInput.parse(newHost, port: newPort) {
        case .failure(let reason):
            problem = reason.message
            return false
        case .success(let address):
            if addresses.contains(address) {
                problem = "\(address.hostPort) is already listed."
                return false
            }
            if let other = owner(address) {
                problem = "\(address.hostPort) is already an address of \(other.displayName)."
                return false
            }
            addresses.append(address)
            selection = address
            cancelAddingAddress()
            return true
        }
    }

    func removeSelected() {
        guard canRemove, let selection else { return }
        let index = addresses.firstIndex(of: selection) ?? 0
        addresses.removeAll { $0 == selection }
        self.selection = addresses.isEmpty ? nil : addresses[min(index, addresses.count - 1)]
    }

    /// What a key does in the sheet. While an address is being typed, Return adds it and Escape
    /// closes the row; otherwise Return saves and Escape cancels the sheet.
    enum KeyAction: Equatable {
        case save
        case cancel
        case addAddress
        case cancelAddingAddress
    }

    var returnAction: KeyAction { isAddingAddress ? .addAddress : .save }
    var escapeAction: KeyAction { isAddingAddress ? .cancelAddingAddress : .cancel }
}

extension DeviceEditModel: Identifiable {}

/// The Connections panel's Edit… sheet: the device's name and its addresses.
struct DeviceEditSheet: View {
    @ObservedObject var model: DeviceEditModel
    let onSave: (_ nickname: String?, _ addresses: [DeviceAddress]) -> Void
    let onCancel: () -> Void

    @FocusState private var newHostFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Device")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.subheadline)
                TextField("Name", text: $model.name, prompt: Text(DeviceEditModel.namePrompt))
                    .textFieldStyle(.roundedBorder)
                Text(DeviceEditModel.namePrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Addresses")
                    .font(.subheadline)

                List(selection: $model.selection) {
                    ForEach(model.addresses, id: \.self) { address in
                        HStack {
                            Text(address.hostPort)
                                .font(.body.monospaced())
                            Spacer()
                            if let tag = address.tag {
                                Text(tag.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                        }
                        .tag(address)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 110)

                HStack(spacing: 4) {
                    Button {
                        model.beginAddingAddress()
                        newHostFocused = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 14, height: 14)
                    }
                    .help("Add an address")
                    .accessibilityLabel("Add Address")
                    .disabled(model.isAddingAddress)

                    Button {
                        model.removeSelected()
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 14, height: 14)
                    }
                    .help("Remove the selected address")
                    .accessibilityLabel("Remove Address")
                    .disabled(!model.canRemove)

                    Spacer()
                }
                .controlSize(.small)

                if model.isAddingAddress {
                    HStack {
                        TextField("Host or IP", text: $model.newHost, prompt: Text("Host or IP"))
                            .textFieldStyle(.roundedBorder)
                            .focused($newHostFocused)
                        TextField("Port", text: $model.newPort, prompt: Text("443"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                        Button("Cancel") { model.cancelAddingAddress() }
                            .keyboardShortcut(.cancelAction)
                        Button("Add") { model.addAddress() }
                            .keyboardShortcut(.defaultAction)
                    }
                }

                if let problem = model.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(model.isAddingAddress ? nil : .cancelAction)
                Button("Save") {
                    let result = model.result
                    onSave(result.nickname, result.addresses)
                }
                .keyboardShortcut(model.isAddingAddress ? nil : .defaultAction)
                .disabled(!model.canSave)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

// MARK: - Linking an address to a saved device

/// The question asked after connecting to an address no saved device has, when its certificate
/// is the one pinned for a saved device: "This is <device>", Add address or Keep separate.
struct DeviceLinkPrompt: Identifiable {
    /// The device as just connected (saved on its own by the connect).
    let connected: KVMDevice
    /// The saved device whose pin matches.
    let candidate: KVMDevice
    /// Whether the address was already saved as a device of its own before this connect (one
    /// saved by an earlier version, say), rather than new.
    var wasSavedSeparately = false

    var id: String { "\(connected.id)->\(candidate.id)" }

    enum Answer: Equatable {
        case addAddress
        case keepSeparate
    }

    static let addTitle = "Add address"
    static let keepTitle = "Keep separate"
    /// Escape keeps the address separate.
    static let escapeAnswer = Answer.keepSeparate

    var title: String { "This is \(candidate.displayName)" }

    var message: String {
        let address = connected.address.labelWithTag
        let lead = wasSavedSeparately
            ? "\(address) is saved as a device of its own (\(connected.displayName)), and it presented the same certificate as \(candidate.displayName). "
            : "\(address) presented the same certificate as \(candidate.displayName). "
        return lead + "Add it as another address of \(candidate.displayName), or keep it as a separate device."
    }

    /// The question to ask after a connect, or nil. `savedBefore` is the saved device that had the
    /// address before the connect started. Asked for an address no saved device had, or that a
    /// saved device had as its only address (as every device saved by an earlier version has),
    /// when the certificate it presented matches the pin of another saved device's address and
    /// the operator has not already chosen to keep the two separate.
    @MainActor
    static func after(connecting connected: KVMDevice, savedBefore: KVMDevice?, catalog: KVMDeviceManager) -> DeviceLinkPrompt? {
        if let savedBefore, savedBefore.addresses.count > 1 {
            return nil
        }
        guard let candidate = catalog.linkCandidate(for: connected) else { return nil }
        return DeviceLinkPrompt(connected: connected, candidate: candidate, wasSavedSeparately: savedBefore != nil)
    }

    /// Carries out the answer. Add address makes the address one of the candidate's, and its
    /// last-used one unless `makeLastUsed` is false; a session connected through it becomes the
    /// candidate's. Keep separate changes nothing.
    @MainActor
    @discardableResult
    func answer(_ answer: Answer, catalog: KVMDeviceManager, makeLastUsed: Bool = true) -> KVMDevice? {
        switch answer {
        case .addAddress:
            let current = catalog.availableDevices.first { $0.id == connected.id } ?? connected
            return catalog.link(connected.address, of: current, to: candidate, makeLastUsed: makeLastUsed)
        case .keepSeparate:
            catalog.declineLink(connected.address, to: candidate)
            return nil
        }
    }
}
