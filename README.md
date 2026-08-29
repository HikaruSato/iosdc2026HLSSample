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
- media segmentの実際の長さを`AVAssetSegmentReport`から取得し、取得できない場合だけ2秒へフォールバックします。
- `init.mp4`を最初に1回アップロードします。
- 各segmentをアップロードしてから、そのsegmentを追加した`playlist.m3u8`をアップロードします。
- 停止時は`#EXT-X-ENDLIST`を追加したplaylistをアップロードします。
- ブラウザは最新のstreamを自動選択し、SafariのネイティブHLSまたは同梱したhls.jsで再生します。

### iOS側の責務

```text
SampleHLSStreamer
  └── HLSSegmentRecorder ── AsyncThrowingStream<HLSFragment> ──> HLSStreamPublisher
                                                                  ├── HLSManifest
                                                                  └── HTTPHLSClient
```

- `HLSSegmentRecorder`はcapture、encode、fMP4 fragment生成だけを担当します。
- `HLSStreamPublisher`はfragmentを1つずつ受け取り、init、segment、playlist、ENDLISTの公開順とretryを管理します。
- `HLSManifest`はplaylistの状態とrender、`HTTPHLSClient`はURLとHTTP PUTだけを担当します。
- `SampleHLSStreamer`はRecorderとPublisherを接続し、停止時に最後のfragmentとENDLISTの公開完了まで待ちます。

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

保存済みのstreamは、そのstreamのディレクトリへ移動し、playlistを入口にして再生確認できます。`.m4s`を単体で開くのではなく、HLS一式を参照する`playlist.m3u8`を`ffplay`へ渡します。

```sh
ffplay playlist.m3u8
```

## 実行

Python 3.10以上を使います。追加パッケージのインストールは不要です。

### 同じネットワークで確認する

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

### 会場でngrok経由のアップロードを確認する

会場のネットワークでiPhoneからMacへ直接接続できない場合は、ngrokをiPhoneからMacへのアップロード経路として使用できます。視聴URLとしてngrok URLを配布せず、Macのブラウザで開いたviewerをスクリーンへ投影します。

```text
iPhone
  └── HTTPS ──> ngrok ──> http://localhost:8080  PUT

Mac browser
  └─────────────────────> http://localhost:8080  GET
```

ngrokを初めて使うMacでは、[ngrok公式のmacOS向け手順](https://ngrok.com/download/mac-os)に従ってインストールし、アカウントのauthtokenを設定します。authtokenはリポジトリへ保存しないでください。

```sh
brew install ngrok
ngrok config add-authtoken "<YOUR_AUTHTOKEN>"
```

会場では次の順番で起動します。

1. MacでHTTPサーバーを起動します。

   ```sh
   python3 server/server.py
   ```

2. 別のターミナルで、Macの8080番ポートをngrokへ公開します。

   ```sh
   ngrok http 8080
   ```

3. ngrokが表示したHTTPS URLを確認します。

   ```text
   Forwarding  https://example.ngrok.app -> http://localhost:8080
   ```

4. iPhoneアプリの`Mac HTTP Server`へ`https://example.ngrok.app`を入力し、`接続確認`を押します。
5. Macのブラウザで`http://localhost:8080`を開きます。ngrokのURLは開きません。
6. iPhoneアプリで`配信開始`を押し、Macのviewerで再生されることを確認します。
7. デモ終了後、`ngrok http 8080`を実行しているターミナルでControl-Cを押し、公開を終了します。

この方法では、iPhoneとMacが同じLANに接続されている必要はありません。双方からインターネットへ接続できれば利用できます。iPhoneからのHLSアップロードとMacからngrokへの接続が同じインターネット回線へ集中しないよう、可能であればMacは有線LAN、iPhoneは別回線で確認します。

ngrok URLを知っている利用者は、このサンプルのGET・PUT APIへアクセスできます。URLを視聴者へ共有せず、デモ直前に起動して終了後すぐに停止してください。URLを秘密にすること自体は認証の代わりにはならないため、長時間の公開や本番利用には使用しません。

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

Mac HTTPサーバーはデモ専用です。認証、TLS、アクセス制御、保存容量の管理は実装していません。通常は同一ネットワーク内だけで使用し、ngrokを使う場合も上記の会場デモ中だけ一時的に公開してください。

ブラウザ再生には同梱したhls.js v1.6.16を使用します。ライセンスは`server/static/vendor/LICENSE.hls.js.txt`を参照してください。
