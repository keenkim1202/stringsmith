import SwiftUI

struct ContentView: View {
    @State private var itemCount = 3
    private let customer = "김소연"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                // 변수가 없는 문자열은 프로퍼티가 된다.
                Text(L10n.App.title).font(.title2).bold()
                Text(L10n.App.subtitle).foregroundStyle(.secondary)
            }

            Divider()

            // 변수가 있으면 함수가 되고, 인자를 빠뜨리면 컴파일이 막는다.
            Text(L10n.Cart.greeting(customer)).font(.headline)

            if itemCount == 0 {
                Text(L10n.Cart.empty).foregroundStyle(.secondary)
            } else {
                // 복수형은 접근자 하나다. 어느 형태를 쓸지는 iOS 가 고른다.
                Text(L10n.Cart.items(itemCount))
            }

            Stepper(value: $itemCount, in: 0...12) {
                Text(L10n.Cart.title)
            }

            // 시트의 "50% 할인" 은 리터럴 퍼센트다. 변수와 섞여도 깨지지 않는다.
            Text(L10n.Cart.discount(customer))
                .font(.callout)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            Spacer()

            HStack {
                Spacer()
                Button(L10n.Common.cancel) {}
                Button(L10n.Common.ok) {}.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

#Preview {
    ContentView()
}
