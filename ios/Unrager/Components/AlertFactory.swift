import UIKit

enum AlertFactory {
    static func error(_ error: Error, title: String = "Something went wrong") -> UIAlertController {
        let alert = UIAlertController(
            title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }
}
