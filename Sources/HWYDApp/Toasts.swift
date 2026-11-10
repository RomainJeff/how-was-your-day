import SwiftUI

/// A short message stacked in the corner of the main window. Information leaves on its own;
/// a toast that offers a decision stays until it is answered or closed.
struct Toast: Identifiable {
    enum Style { case info, success, error }
    let id = UUID()
    var style: Style
    var message: String
    var actions: [ToastAction] = []
    /// Stays until closed, even without actions.
    var sticky = false
    /// Leaves on its own even with actions: an offer such as « Annuler » that does not need an answer.
    var optional = false
    var staysOnScreen: Bool { sticky || (!actions.isEmpty && !optional) }
    /// Long enough to read a sentence; errors and optional actions get more time.
    var lifetime: Duration { style == .error || !actions.isEmpty ? .seconds(8) : .seconds(5) }
}

struct ToastAction: Identifiable {
    let id = UUID()
    var title: String
    var run: @MainActor () -> Void
}

struct ToastStack: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { toast in
                ToastView(toast: toast)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(20)
        .animation(.spring(duration: 0.3), value: model.toasts.map(\.id))
    }
}

private struct ToastView: View {
    @EnvironmentObject var model: AppModel
    let toast: Toast
    @State private var hovering = false
    private var color: Color { toast.style == .error ? Studio.copper : Studio.mint }
    private var symbol: String {
        switch toast.style {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: Studio.Size.heading)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 10) {
                Text(toast.message).font(.system(size: Studio.Size.body)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if !toast.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(toast.actions.enumerated()), id: \.element.id) { index, action in
                            Button(action.title) { model.runToastAction(action, of: toast) }
                                .buttonStyle(StudioButtonStyle(primary: index == 0, destructive: toast.style == .error && index == 0, compact: true))
                        }
                    }
                }
            }
            Button { model.dismissToast(toast.id) } label: {
                Image(systemName: "xmark").font(.system(size: Studio.Size.caption, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Studio.muted).accessibilityLabel("Fermer")
        }
        .padding(14).frame(width: 360, alignment: .leading)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(toast.style == .error ? Studio.copper.opacity(0.5) : Studio.line))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .foregroundStyle(Studio.text)
        // Clicking the toast runs its main action, when it has one.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { if let first = toast.actions.first { model.runToastAction(first, of: toast) } }
        .onHover { inside in hovering = inside; model.holdToast(toast.id, inside) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(toast.style == .error ? .isStaticText : [])
    }
}
