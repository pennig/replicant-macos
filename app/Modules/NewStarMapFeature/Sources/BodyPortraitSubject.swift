import UniverseModels

/// What a location detail header's 128pt square renders.
public enum BodyPortrait: Equatable, Sendable {
    case star(SystemStar)
    case planet(Planet)
    case moon(Moon)
    case belt(Belt)
    /// A Kuiper belt or Oort cloud, drawn as a wide sparse point field.
    case region(SpecialSite)
}
