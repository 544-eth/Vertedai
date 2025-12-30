import Foundation
import Combine
import SwiftUI

class AppState: ObservableObject {
    @Published var chatViewModel: ChatViewModel = ChatViewModel()
    @Published var radarViewModel: RadarViewModel = RadarViewModel()
    @Published var friendsViewModel: FriendsViewModel = FriendsViewModel()
 
    
}

