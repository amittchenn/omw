import SwiftUI
import WidgetKit

// The widget extension only holds omw!'s Live Activity (no home screen widget).
@main
struct OmwLiveBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.2, *) {
            OmwLiveLiveActivity()
        }
    }
}
