import ComposableArchitecture
import SwiftUI
import UI
import Utils

struct Response: Equatable {
    struct Header: Identifiable, Equatable {
        let name: String
        let value: String
        var id: String { name }
    }
    
    let response: HTTPURLResponse
    let data: Data
    let duration: Duration
    
    var statusCode: Int {
        response.statusCode
    }
    
    var status: String {
        statusCode != 200 ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : "OK"
    }

    /// A short, human-readable size of the response body (e.g. `"100 bytes"` or `"1.2 KB"`).
    var byteCountReadout: String {
        data.count.formatted(.byteCount(style: .file))
    }

    /// The response body decoded as text, exactly as received over the wire.
    var rawString: String {
        String(decoding: data, as: UTF8.self)
    }

    /// The response headers as sortable rows, ordered alphabetically by name.
    var headers: [Header] {
        response.allHeaderFields
            .map { Header(name: "\($0.key)", value: "\($0.value)") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum ResponseContentSelection: String, CaseIterable, Identifiable {
    case tree = "Tree"
    case raw = "Raw"
    case headers = "Headers"
    
    var id: String {
        self.rawValue
    }
}

@Reducer
public struct ResponsePaneFeature {
    @ObservableState
    public struct State: Equatable {
        var response: Response
        var contentSelection: ResponseContentSelection = .tree
        
        var jsonTreeNode: JSONTreeNode {
            let value = try? JSONDecoder().decode(JSONValue.self, from: response.data)
            return JSONTreeNode(value: value ?? .null)
        }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
    }

    public init() {}

    public var body: some Reducer<State, Action> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none
            case .onAppear:
                return .none
            }
        }
    }
}

public struct ResponsePaneView: View {
    @Bindable var store: StoreOf<ResponsePaneFeature>
    
    public init(store: StoreOf<ResponsePaneFeature>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                StatusDot(statusCode: store.response.statusCode)
                Text("\(store.response.statusCode) \(store.response.status)")
                    .foregroundStyle(HTTPStatusStyle.color(store.response.statusCode))
                Text(store.response.duration.apiCallReadout)
                    .foregroundStyle(.rcTextSecondary)
                Text(store.response.byteCountReadout)
                    .foregroundStyle(.rcTextSecondary)
                Spacer()
                RCSegmentedControl(selection: $store.contentSelection, options: ResponseContentSelection.allCases) { option in
                    option.rawValue
                }
            }
            .padding(Space.s)
            Divider()
            switch store.contentSelection {
            case .tree:
                JSONTreeView(node: store.jsonTreeNode)
            case .raw:
                FindableTextView(store.response.rawString)
            case .headers:
                Table(store.response.headers) {
                    TableColumn("Header") { header in
                        Text(header.name)
                            .foregroundStyle(.rcJSONKey)
                            .textSelection(.enabled)
                            .frame(minHeight: 20)
                    }
                    TableColumn("Value") { header in
                        Text(header.value)
                            .foregroundStyle(.rcTextPrimary)
                            .textSelection(.enabled)
                            .frame(minHeight: 20)
                    }
                }
                .font(.rcMono)
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
    }
}

#Preview {
    ResponsePaneView(
        store: Store(initialState: .init(response: .mock)){
            ResponsePaneFeature()
        }
    ).background(.rcWindowBackground)
}

extension Response {
    static let mock = Self(
        response: .mock(statusCode: 200),
        data: .mockDeviceJSON,
        duration: .milliseconds(342)
    )
}

extension Data {
    /// A representative `GET /devices/{code}` response body for previews and tests.
    static let mockDeviceJSON = Data(
        """
        {
          "device_code": "VES-7F3A2",
          "device_type": "vessel",
          "status": "mining",
          "replicant_code": "RPL-0001",
          "location": "LACASAW-3",
          "location_name": "La Casawary III",
          "operational_capacity": 0.87,
          "queue_size": 2,
          "message": "This is a message to inform you that your vehicle's factory warranty will expire soon, and that you can save",
          "features": ["cargo_hold", "mining_laser", "warp_drive"],
          "available_commands": ["travel", "mine", "scan", "stow", "repair"],
          "controller_device_code": "HUB-001A4",
          "beacon_only": false,
          "cargo_used": 142.5,
          "cargo_capacity": 200,
          "cargo": [
            { "resource": "iron_ore", "quantity": 96.0 },
            { "resource": "silicate", "quantity": 46.5 }
          ],
          "mining": {
            "target_device_code": "AST-44C19",
            "resource": "iron_ore",
            "rate_per_hour": 12.4,
            "completes_at": "2026-06-19T18:42:00Z"
          },
          "travel": null,
          "attached_devices": [],
          "ami_directive": null
        }
        """.utf8
    )
}

extension HTTPURLResponse {
    static func mock(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://replicant.space")!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(Data.mockDeviceJSON.count)",
                "Date": "Fri, 19 Jun 2026 18:21:04 GMT",
                "Server": "replicant.space",
                "X-RateLimit-Limit": "120",
                "X-RateLimit-Remaining": "118",
                "X-RateLimit-Reset": "1750357320",
                "X-Request-Id": "req_8f3a2c19d4",
            ]
        )!
    }
}
