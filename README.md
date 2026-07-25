# iosdc2026HLSSample

iOSDC Japan 2026 の登壇「映像変換サーバーなしでiPhone端末内でHLSを生成してライブ配信」で説明するための最小サンプルアプリです。

MomentNow 本体から、HLS 生成に関係する部分だけを抜き出しています。S3 へのアップロード、API、SwiftData、課金、共有、視聴数は含めず、端末ローカルに HLS ファイルを保存して再生します。

## できること

- カメラとマイクの `CMSampleBuffer` を `AVAssetWriter` へ渡す
- `AVAssetWriterDelegate` から `init.mp4` と `.m4s` segment を受け取る
- `Documents/HLSStreams/{streamId}` に HLS ファイルを保存する
- `playlist.m3u8` を segment 追加ごとに更新する
- 停止時に `#EXT-X-ENDLIST` を付ける
- ローカルの `playlist.m3u8` を AVPlayer / WebView で再生する

## ファイル構成

```text
Documents/HLSStreams/{streamId}/
├── index.html
├── init.mp4
├── playlist.m3u8
└── seg/
    ├── 000001.m4s
    ├── 000002.m4s
    └── ...
```

## ビルド

```sh
xcodebuild -project iosdc2026HLSSample.xcodeproj -scheme iosdc2026HLSSample build -destination 'generic/platform=iOS Simulator'
```

## テスト

```sh
xcodebuild -project iosdc2026HLSSample.xcodeproj -scheme iosdc2026HLSSample build-for-testing -destination 'generic/platform=iOS Simulator'
```

Simulatorで実行テストまで行う場合は、利用可能なSimulatorを指定してください。

```sh
xcodebuild -project iosdc2026HLSSample.xcodeproj -scheme iosdc2026HLSSample test -destination 'platform=iOS Simulator,name=iPhone 16,OS=26.2'
```

実機で録画する場合は、カメラとマイクの権限を許可してください。WebView再生は `index.html` を `WKWebView.loadFileURL` で開く簡易確認です。Safari再生は端末内HTTPサーバーが必要になるため、このサンプルには含めていません。
