# iosdc2026HLSSample

iPhone端末内でHLSを生成し、HTTPでオブジェクトサーバーへアップロードしてライブ配信する流れを確認するためのサンプルです。

本番構成のS3へのアップロードとCloudFrontからの配信を、Mac上の小さなHTTPサーバーで置き換えています。iOS側のHLS生成とアップロード順序を説明しやすくすることが目的です。

## 構成

```text
iPhone
  AVAssetWriter
    ├── init.mp4 ─────────────── PUT ─┐
    ├── seg/000001.m4s ───────── PUT ─┼─> Mac HTTP server
    └── playlist.m3u8 ────────── PUT ─┘       │
                                                │ GET
                                                v
                                         Browser viewer
```

- iOSはカメラとマイクの`CMSampleBuffer`を`AVAssetWriter`へ渡します。
- `AVAssetWriterDelegate`から`init.mp4`とfragmented MP4のsegmentを受け取ります。
- `init.mp4`を最初に1回アップロードします。
- 各segmentをアップロードしてから、そのsegmentを追加した`playlist.m3u8`をアップロードします。
- 停止時は`#EXT-X-ENDLIST`を追加したplaylistをアップロードします。
- ブラウザは最新のstreamを自動選択し、SafariのネイティブHLSまたは同梱したhls.jsで再生します。

## ディレクトリ

```text
.
├── ios/
│   ├── iosdc2026HLSSample.xcodeproj/
│   ├── iosdc2026HLSSample/
│   └── iosdc2026HLSSampleTests/
└── server/
    ├── server.py
    ├── static/
    └── tests/
```

受信したHLSオブジェクトは、実行時に次の構成で`server/data/`へ保存されます。

```text
server/data/streams/{streamId}/
├── init.mp4
├── playlist.m3u8
└── seg/
    ├── 000001.m4s
    ├── 000002.m4s
    └── ...
```

## 実行

Python 3.10以上を使います。追加パッケージのインストールは不要です。

1. MacでHTTPサーバーを起動します。

   ```sh
   python3 server/server.py
   ```

2. Macのブラウザで`http://localhost:8080`を開きます。
3. MacとiPhoneを同じネットワークへ接続します。
4. サーバー起動時に表示される`http://<MacのIPアドレス>:8080`をiOSアプリの`Mac HTTP Server`へ入力し、`接続確認`を押します。
5. `ios/iosdc2026HLSSample.xcodeproj`をXcodeで開き、実機でアプリを実行します。
6. カメラとマイクの権限を許可し、`配信開始`を押します。

macOSのファイアウォール確認が表示された場合は、Pythonからの受信接続を許可してください。iOS SimulatorからMac上のサーバーへ接続する場合は`http://localhost:8080`を使用できます。

ポートや保存先は起動オプションで変更できます。

```sh
python3 server/server.py --port 8090 --data-dir /tmp/iosdc-hls
```

## HTTP API

| Method | Path | 用途 |
| --- | --- | --- |
| `GET` | `/health` | iOSからの接続確認 |
| `PUT` | `/streams/{streamId}/init.mp4` | initialization segmentの保存 |
| `PUT` | `/streams/{streamId}/seg/{sequence}.m4s` | media segmentの保存 |
| `PUT` | `/streams/{streamId}/playlist.m3u8` | playlistの作成・置換 |
| `GET` | `/api/streams` | viewer用のstream一覧 |
| `GET` | `/streams/{streamId}/...` | HLSオブジェクトの配信 |

サーバーはPUTを一時ファイルへ書き込み、完了後に置換します。ブラウザが書き込み途中のplaylistやsegmentを取得しないためです。

## ビルドとテスト

```sh
xcodebuild \
  -project ios/iosdc2026HLSSample.xcodeproj \
  -scheme iosdc2026HLSSample \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

利用可能なSimulator名またはIDを指定してiOSのテストを実行します。

```sh
xcodebuild \
  -project ios/iosdc2026HLSSample.xcodeproj \
  -scheme iosdc2026HLSSample \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Mac HTTPサーバーのテストは次のコマンドで実行します。

```sh
python3 -m unittest discover -s server/tests -v
```

## 注意

Mac HTTPサーバーは同一ネットワーク内でのデモ専用です。認証、TLS、アクセス制御、保存容量の管理は実装していないため、インターネットへ公開しないでください。

ブラウザ再生には同梱したhls.js v1.6.16を使用します。ライセンスは`server/static/vendor/LICENSE.hls.js.txt`を参照してください。
