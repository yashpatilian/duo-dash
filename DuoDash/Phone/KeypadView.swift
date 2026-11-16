import SwiftUI

/// Big dial pad. Keys grow to fill the space and never drop below the minimum
/// touch size; side by side with the number on wide, short windows.
struct KeypadView: View {
    @Environment(ContactsStore.self) private var contacts
    @State private var number = ""

    static let keys: [[(digit: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let spacing: CGFloat = 10
            // Landscape-ish: pad on the left, number + call on the right.
            let sideBySide = size.width > size.height * 1.25
            if sideBySide {
                let padWidth = min(size.width * 0.58, (size.height - 3 * spacing) / 4 * 1.6 * 3 + 2 * spacing)
                HStack(spacing: 16) {
                    pad(width: padWidth, height: size.height, spacing: spacing)
                    VStack(spacing: 16) {
                        Spacer(minLength: 0)
                        display
                        callButton
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if size.height < 6 * Theme.minTouch + 5 * spacing {
                // Short and narrow (Split View, cover screen with the mini player):
                // the number on top, delete and call in a fourth column.
                compact(size: size)
            } else {
                let keyHeight = max(Theme.minTouch, min(84, (size.height - 2 * Theme.minTouch - 6 * spacing) / 4))
                VStack(spacing: spacing) {
                    display
                    pad(width: min(size.width, 420), height: 4 * keyHeight + 3 * spacing, spacing: spacing)
                    callButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 6)
    }

    private func compact(size: CGSize) -> some View {
        let spacing: CGFloat = 4
        let textHeight: CGFloat = 28
        let width = min(size.width, 440)
        let keyWidth = max(Theme.minTouch, (width - 3 * spacing) / 4)
        let keyHeight = max(Theme.minTouch, (size.height - textHeight - 4 * spacing) / 4)
        return ScrollView {
            VStack(spacing: spacing) {
                numberText.frame(height: textHeight)
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    ForEach(Self.keys.indices, id: \.self) { row in
                        GridRow {
                            ForEach(Self.keys[row], id: \.digit) { key in
                                keyButton(key.digit, letters: key.letters, width: keyWidth, height: keyHeight)
                            }
                            switch row {
                            case 0: deleteButton.frame(width: keyWidth, height: keyHeight)
                            case 3:
                                callButtonLabel(width: keyWidth, height: keyHeight)
                            default: Color.clear.frame(width: keyWidth, height: keyHeight)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .padding(.top, -6)  // reclaim the tab gap: every point counts here
    }

    private var numberText: some View {
        Text(number.isEmpty ? "Enter a number" : number)
            .font(number.isEmpty ? .dashBody : .system(size: 30, weight: .semibold).monospacedDigit())
            .foregroundStyle(number.isEmpty ? Theme.textSecondary : Theme.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("phone.keypad.display")
            .accessibilityLabel(number.isEmpty ? "No number" : number)
    }

    @ViewBuilder
    private var deleteButton: some View {
        if !number.isEmpty {
            Button {
                number.removeLast()
            } label: {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minWidth: Theme.minTouch, maxWidth: .infinity, minHeight: Theme.minTouch, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in number = "" })
            .accessibilityLabel("Delete")
            .accessibilityIdentifier("phone.keypad.delete")
        } else {
            Color.clear
        }
    }

    private var display: some View {
        HStack(spacing: 4) {
            numberText
            if !number.isEmpty { deleteButton.frame(width: Theme.minTouch, height: Theme.minTouch) }
        }
        .frame(minHeight: Theme.minTouch)
    }

    private func pad(width: CGFloat, height: CGFloat, spacing: CGFloat) -> some View {
        let keyHeight = max(Theme.minTouch, (height - 3 * spacing) / 4)
        let keyWidth = max(Theme.minTouch, (width - 2 * spacing) / 3)
        return Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(Self.keys.indices, id: \.self) { row in
                GridRow {
                    ForEach(Self.keys[row], id: \.digit) { key in
                        keyButton(key.digit, letters: key.letters, width: keyWidth, height: keyHeight)
                    }
                }
            }
        }
        .frame(width: width)
    }

    private func keyButton(_ digit: String, letters: String, width: CGFloat, height: CGFloat) -> some View {
        Button {
            guard number.count < 32 else { return }
            number.append(digit)
        } label: {
            VStack(spacing: 0) {
                Text(digit).font(.system(size: min(36, height * 0.46), weight: .regular))
                if !letters.isEmpty, height >= 70 {
                    Text(letters).font(.system(size: 11, weight: .semibold)).kerning(1.5)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: width, height: height)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: min(height / 2, 22), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            // Long-press 0 for +, as on the Phone app.
            if digit == "0", number.hasSuffix("0") { number.removeLast(); number.append("+") }
        })
        .accessibilityLabel(digit)
        .accessibilityIdentifier("phone.keypad.\(Self.keyID(digit))")
    }

    static func keyID(_ digit: String) -> String {
        switch digit {
        case "*": "star"
        case "#": "hash"
        default: digit
        }
    }

    private var callButton: some View {
        callButtonLabel(width: Theme.minTouch * 1.8, height: Theme.minTouch)
    }

    private func callButtonLabel(width: CGFloat, height: CGFloat) -> some View {
        Button {
            contacts.call(Recipient(name: "", number: number))
        } label: {
            Image(systemName: "phone.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: width, height: height)
                .background(Theme.positive.opacity(number.isEmpty ? 0.4 : 1), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .disabled(number.isEmpty)
        .accessibilityLabel("Call")
        .accessibilityIdentifier("phone.call")
    }
}
