import Foundation

enum FileUploadRequest {
    static func prepare(_ request: URLRequest, upload: FileUploadDescriptor, file: URL) throws -> URLRequest {
        guard upload.isValid, file.isFileURL,
            let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "https", components.host?.isEmpty == false,
            components.user == nil, components.password == nil, components.fragment == nil,
            ["POST", "PUT", "PATCH"].contains(request.httpMethod),
            request.httpBody == nil, request.httpBodyStream == nil
        else {
            throw FileUploadError.invalid(
                "A file upload requires a local file and an HTTPS POST, PUT, or PATCH request.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.int64Value == upload.byteCount
        else { throw FileUploadError.invalid("The upload source is not a regular file of the expected length.") }
        if let declared = request.value(forHTTPHeaderField: "Content-Length"), declared != String(upload.byteCount) {
            throw FileUploadError.invalid("Content-Length does not match the upload file.")
        }
        var result = request
        result.setValue(String(upload.byteCount), forHTTPHeaderField: "Content-Length")
        if result.value(forHTTPHeaderField: "Content-Type") == nil {
            result.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return result
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme == rhs.scheme && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }
}
