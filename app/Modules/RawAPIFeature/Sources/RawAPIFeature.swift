//
//  RawAPIFeature.swift
//  Replicant
//
//  The direct API access feature for power users. A self-contained three-column
//  experience: a session-scoped request history (sidebar), a request composer
//  (content), and the raw response inspector (detail). Compose a request against
//  the Replicant Space API surface and inspect the raw response.
//

import ComposableArchitecture
import SwiftUI
import SwiftUIIntrospect
import UI
import Utils

// MARK: - Reducer

@Reducer
public struct RawAPIFeature {
    @ObservableState
    public struct State: Equatable {
        /// The session API key, injected as a bearer token on every request.
        /// Passed in by the host; empty in standalone previews.
        var apiKey: String
        /// The request currently being composed (or restored from history).
        var draft: RawRequest
        var isSending: Bool
        /// A transport-level failure (no HTTP response). A non-2xx response is a
        /// valid `responsePane`, not an error.
        var requestError: String?
        /// The detail pane, present once a response is available.
        var responsePane: ResponsePaneFeature.State?
        /// History of requests made this app session. In-memory so it survives
        /// the window closing and reopening, but never touches disk.
        @Shared(.inMemory("rawAPIHistory")) var history: [RequestHistoryItem] = []
        var selectedHistoryID: RequestHistoryItem.ID?

        public init(apiKey: String = "") {
            self.apiKey = apiKey
            self.draft = RawRequest()
            self.isSending = false
            self.requestError = nil
            self.responsePane = nil
            self.selectedHistoryID = nil
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case addQueryRowButtonTapped
        // Rows are keyed by their UUID id; spelled as `UUID` rather than
        // `KeyValuePair.ID` so this public action doesn't expose the internal type.
        case deleteQueryRow(UUID)
        case sendButtonTapped
        case requestSucceeded(CapturedResponse)
        case requestFailed(String)
        case responsePane(ResponsePaneFeature.Action)
    }

    public init() {}

    @Dependency(\.rawAPIClient) var rawAPIClient
    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    public var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.selectedHistoryID):
                // Selecting a history entry restores its request into the editor
                // and re-displays the saved response.
                guard
                    let id = state.selectedHistoryID,
                    let item = state.history.first(where: { $0.id == id })
                else { return .none }
                state.draft = item.request
                state.requestError = nil
                state.responsePane = ResponsePaneFeature.State(response: item.response.asResponse)
                return .none

            case .binding:
                return .none

            case .addQueryRowButtonTapped:
                state.draft.queryItems.append(KeyValuePair(id: uuid()))
                return .none

            case let .deleteQueryRow(id):
                state.draft.queryItems.removeAll { $0.id == id }
                return .none

            case .sendButtonTapped:
                guard !state.isSending else { return .none }
                state.isSending = true
                state.requestError = nil
                let request = state.draft
                let apiKey = state.apiKey
                let client = rawAPIClient
                return .run { send in
                    do {
                        let captured = try await client.send(request, apiKey)
                        await send(.requestSucceeded(captured))
                    } catch {
                        await send(.requestFailed(error.localizedDescription))
                    }
                }

            case let .requestSucceeded(captured):
                state.isSending = false
                let item = RequestHistoryItem(
                    id: uuid(),
                    request: state.draft,
                    response: captured,
                    date: date.now
                )
                state.$history.withLock { $0.insert(item, at: 0) }
                state.selectedHistoryID = item.id
                state.responsePane = ResponsePaneFeature.State(response: captured.asResponse)
                return .none

            case let .requestFailed(message):
                state.isSending = false
                state.requestError = message
                state.responsePane = nil
                return .none

            case .responsePane:
                return .none
            }
        }
        .ifLet(\.responsePane, action: \.responsePane) {
            ResponsePaneFeature()
        }
    }
}

// MARK: - Root view

public struct RawAPIView: View {
    @Bindable var store: StoreOf<RawAPIFeature>

    public init(store: StoreOf<RawAPIFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            HistorySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 340)
        } content: {
            RequestEditor(store: store)
                .navigationSplitViewColumnWidth(min: 380, ideal: 400, max: 620)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 380, ideal: 500)
                .navigationTitle("Response")
        }
    }

    @ViewBuilder private var detail: some View {
        if let responseStore = store.scope(state: \.responsePane, action: \.responsePane) {
            ResponsePaneView(store: responseStore)
        } else if let error = store.requestError {
            ResponsePlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Request Failed",
                message: error,
                tint: .rcDanger
            )
        } else {
            ResponsePlaceholder(
                systemImage: "arrow.left.arrow.right",
                title: "No Response Yet",
                message: "Compose a request and send it to inspect the response here.",
                tint: .rcTextTertiary
            )
        }
    }
}

/// Centered icon + title + message used for the empty / error detail states.
private struct ResponsePlaceholder: View {
    let systemImage: String
    let title: String
    let message: String
    var tint: Color = .rcTextTertiary

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            Text(title)
                .font(.rcTitle)
                .foregroundStyle(.rcTextPrimary)
            Text(message)
                .font(.rcBody)
                .foregroundStyle(.rcTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar: request history

private struct HistorySidebar: View {
    @Bindable var store: StoreOf<RawAPIFeature>

    var body: some View {
        Group {
            if store.history.isEmpty {
                VStack(spacing: Space.s) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.rcTextTertiary)
                    Text("No requests yet")
                        .font(.rcBody)
                        .foregroundStyle(.rcTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SelectableList(
                    store.history,
                    selection: $store.selectedHistoryID
                ) { item, isSelected in
                    HistoryRow(item: item)
                        .tag(item.id)
                        .rcSidebarRow(isSelected: isSelected)
                }
            }
        }
        .background(.rcSidebarBackground)
        .navigationTitle("History")
    }
}

private struct HistoryRow: View {
    let item: RequestHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                MethodTag(method: item.request.method)
                StatusDot(statusCode: item.statusCode)
                Text("\(item.statusCode)")
                    .font(.rcMonoSmall)
                    .foregroundStyle(HTTPStatusStyle.color(item.statusCode))
                Spacer(minLength: 0)
                Text(item.date.formatted(.dateTime.hour().minute().second()))
                    .font(.rcCaption)
                    .foregroundStyle(.rcTextTertiary)
            }
            Text(item.request.path.isEmpty ? "/" : item.request.path)
                .font(.rcMono)
                .foregroundStyle(.rcTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Content: request composer

private struct RequestEditor: View {
    @Bindable var store: StoreOf<RawAPIFeature>

    var body: some View {
        VStack(spacing: 0) {
            requestBar
                .padding(Space.m)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    EditorSection(title: "Query Parameters") {
                        KeyValueEditor(
                            rows: $store.draft.queryItems,
                            addTitle: "Add parameter",
                            emptyText: "No query parameters.",
                            onAdd: { store.send(.addQueryRowButtonTapped) },
                            onDelete: { store.send(.deleteQueryRow($0)) }
                        )
                    }
                    EditorSection(title: "Body") {
                        BodyEditor(method: store.draft.method, text: $store.draft.body)
                    }
                }
                .padding(Space.m)
            }
        }
        .background(.rcContentBackground)
        .navigationTitle("Request")
    }

    // — Method · path · send —
    private var requestBar: some View {
        HStack(spacing: Space.s) {
            MethodPicker(method: $store.draft.method)
            RCInlineField(placeholder: "/devices/VES-7F3A2", text: $store.draft.path)
            Button {
                store.send(.sendButtonTapped)
            } label: {
                if store.isSending {
                    ProgressView().controlSize(.small).frame(width: 44)
                } else {
                    HStack(spacing: Space.xs) {
                        Text("Send")
                        Image(systemName: "arrow.right")
                    }
                }
            }
            .buttonStyle(RCButtonStyle(.primary))
            .disabled(store.isSending || store.draft.path.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Section wrapper

/// An uppercase section label over its content, matching the design system's
/// `rcSectionLabel` treatment used elsewhere in the app.
private struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title.uppercased())
                .font(.rcSectionLabel)
                .kerning(1)
                .foregroundStyle(.rcTextTertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Method controls

/// Compact dropdown for the HTTP method — a mono label + chevron in a field-style
/// pill, much narrower than `RCValueSelect` so it sits inline with the URL.
private struct MethodPicker: View {
    @Binding var method: HTTPMethod

    var body: some View {
        Menu {
            Picker("Method", selection: $method) {
                ForEach(HTTPMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: Space.xs) {
                Text(method.rawValue)
                    .font(.rcMonoSmall)
                    .foregroundStyle(method.tone)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.rcTextSecondary)
            }
            .padding(.horizontal, Space.s)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(.rcSurfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(.rcSeparator, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The small colored method chip shown in history rows.
private struct MethodTag: View {
    let method: HTTPMethod

    var body: some View {
        Text(method.rawValue)
            .font(.rcMonoSmall)
            .foregroundStyle(method.tone)
            .padding(.vertical, 2)
            .padding(.horizontal, Space.xs)
            .background(
                method.tone.opacity(0.14),
                in: RoundedRectangle(cornerRadius: Radius.textBadge, style: .continuous)
            )
    }
}

private extension HTTPMethod {
    /// Reuses the status color tokens to give each verb a distinct, on-brand hue.
    var tone: Color {
        switch self {
        case .get:    .rcStatusReady
        case .post:   .rcStatusWorking
        case .put:    .rcStatusSensing
        case .patch:  .rcStatusTransit
        case .delete: .rcDanger
        }
    }
}

// MARK: - Key/value editor (query params · headers)

private struct KeyValueEditor: View {
    @Binding var rows: [KeyValuePair]
    let addTitle: String
    let emptyText: String
    let onAdd: () -> Void
    let onDelete: (KeyValuePair.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if rows.isEmpty {
                Text(emptyText)
                    .font(.rcBody)
                    .foregroundStyle(.rcTextTertiary)
            }
            ForEach($rows) { $row in
                HStack(spacing: Space.s) {
                    RCInlineField(placeholder: "Name", text: $row.name)
                    RCInlineField(placeholder: "Value", text: $row.value)
                    Button {
                        onDelete(row.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.rcTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(addTitle, action: onAdd)
                .buttonStyle(RCButtonStyle(.text))
                .padding(.top, Space.xs)
        }
    }
}

// MARK: - Body editor

private struct BodyEditor: View {
    let method: HTTPMethod
    @Binding var text: String

    var body: some View {
        if method.allowsBody {
            TextEditor(text: $text)
                .introspect(.textEditor, on: .macOS(.v26)) { textView in
                    textView.isAutomaticQuoteSubstitutionEnabled = false
                    textView.isAutomaticDashSubstitutionEnabled = false
                    textView.isAutomaticTextReplacementEnabled = false
                }
                .padding(Space.s)
                .frame(minHeight: 160)
                .font(.rcMono)
                .foregroundStyle(.rcTextPrimary)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(.rcSurfaceRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(.rcSeparator, lineWidth: 1)
                        )
                )
        } else {
            HStack(spacing: Space.s) {
                Image(systemName: "nosign")
                    .font(.system(size: 13))
                    .foregroundStyle(.rcTextTertiary)
                Text("\(method.rawValue) requests don't send a body.")
                    .font(.rcBody)
                    .foregroundStyle(.rcTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Inline field (focus-ring text field)

/// A bare `TextField` styled with the design system's field treatment, owning
/// its own focus state so the amber focus ring draws correctly. Mono by default,
/// since these hold paths / codes / header values.
private struct RCInlineField: View {
    let placeholder: String
    @Binding var text: String
    var mono: Bool = true

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .rcField(focused: focused, mono: mono)
    }
}

// MARK: - Status helpers

enum HTTPStatusStyle {
    /// Success (2xx) → green, warning (3xx/4xx) → amber, error (5xx and anything
    /// unexpected) → red. Maps to the semantic outcome tokens.
    static func color(_ statusCode: Int) -> Color {
        switch statusCode {
        case 200..<300: .rcSuccess
        case 300..<500: .rcWarning
        default:        .rcError
        }
    }
}

/// A small glowing dot tinted by an HTTP status code's outcome.
struct StatusDot: View {
    let statusCode: Int

    var body: some View {
        let color = HTTPStatusStyle.color(statusCode)
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

// MARK: - Preview

#Preview {
    RawAPIView(
        store: Store(initialState: RawAPIFeature.State(apiKey: "preview")) {
            RawAPIFeature()
        }
    )
    .background(.rcWindowBackground)
    .frame(width: 1100, height: 680)
}
