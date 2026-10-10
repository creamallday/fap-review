import ReviewCore
import UniformTypeIdentifiers

extension CriteriaImporter {
    static var contentTypes: [UTType] {
        supportedExtensions.compactMap { UTType(filenameExtension: $0) }
    }
}
