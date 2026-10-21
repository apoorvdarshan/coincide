import Foundation

public enum ACPConfigurationOptions {
    public static func values(_ option: JSONValue) -> [JSONValue] {
        (option["options"].array ?? []).flatMap { item in item["options"].array ?? [item] }
    }
    public static func models(_ setup: JSONValue) -> [ProviderModel] {
        if let option = setup["configOptions"].array?.first(where: { $0["category"].string == "model" && $0["type"].string == "select" }) {
            return values(option).compactMap {
                guard let id = $0["value"].string else { return nil }; return .init(id: id, name: $0["name"].string ?? id)
            }
        }
        return (setup["models"]["availableModels"].array ?? []).compactMap {
            guard let id = $0["modelId"].string else { return nil }; return .init(id: id, name: $0["name"].string ?? id)
        }
    }
}
