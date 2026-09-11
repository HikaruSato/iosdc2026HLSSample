
# iosdc2026HLSSample

iPhone端末内でHLSを生成し、HTTPでオブジェクトサーバーへアップロードしてライブ配信する流れを確認するためのサンプルです。

本番構成のS3へのアップロードとCloudFrontからの配信を、Mac上の小さなHTTPサーバーで置き換えています。iOS側のHLS生成とアップロード順序を説明しやすくすることが目的です。

## スクリーンショット

### アプリ

https://github.com/user-attachments/assets/6b40f4e5-ddc9-450e-84df-ee625065a6dd


### ブラウザ

https://github.com/user-attachments/assets/0125016f-4d88-43f4-a8e7-82e7754504c5


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
- `AVAssetWriter.inputReceiver(for:)`でVideo／Audio Inputを接続し、`SampleBufferReceiver`へsampleを書き込みます。
- `AVAssetWriterDelegate`から`init.mp4`とfragmented MP4のsegmentを受け取ります。
- media segmentの実際の長さを`AVAssetSegmentReport`のvideo trackから取得し、有効な値が得られない場合は設定したsegment間隔（既定2秒）へフォールバックします。
- `init.mp4`を最初に1回アップロードします。
- 各segmentをアップロードしてから、そのsegmentを追加した`playlist.m3u8`をアップロードします。
- playlistは過去のsegmentを保持するEVENT形式です。正常停止時は、initと1つ以上のmedia segmentが公開済みの場合に`#EXT-X-ENDLIST`を追加したplaylistをアップロードします。
- ブラウザは1秒ごとにstream一覧を取得し、playlistの更新時刻が最も新しいstream（終了済みも含む）を自動選択します。ネイティブHLSに対応するブラウザではその機能を使い、それ以外では同梱したhls.jsで再生します。初期状態はミュートです。

### iOS側の責務

```text
SampleHLSStreamer
  └── HLSSegmentRecorder ── AsyncThrowingStream<HLSFragment> ──> HLSStreamPublisher
                                                                  ├── HLSManifest
                                                                  └── HTTPHLSClient
```

- `HLSSegmentRecorder`はcaptureとHLS生成を担当し、同じ撮影データを`LocalVideoWriter`にも渡して保存用MP4を並行生成します。
- `LocalVideoWriter`は縦向き1080×1920・HEVC（H.265）Main・映像5 Mbps、AAC・96 kbps・44.1 kHz・モノラルでMP4を生成します。
- HLSには時刻補正したコピー、MP4には撮影時刻のコピーを渡し、両Writerのdropと失敗を独立して扱います。
- `HLSStreamPublisher`はfragmentを1つずつ受け取り、init、segment、playlist、ENDLISTの公開順とretryを管理します。
- `HLSManifest`はplaylistの状態とrender、`HTTPHLSClient`はURLの組み立て、接続確認（`GET /health`）、HTTP PUTとレスポンスの検証を担当します。
- `SampleHLSStreamer`はRecorderとPublisherを接続し、停止時にWriterの終了、写真保存処理、Publisherの終了を待ちます。正常時は最後のfragmentとENDLISTの公開まで行います。
- `PhotoVideoSaver`は完成したMP4を写真ライブラリへ保存します。MP4をサーバーへアップロードしません。

各PUTは初回を含めて最大3回試行します。失敗が確定するとエラーを表示し、その配信では以降のHLS公開を行いません。HLS生成に失敗した場合もENDLISTは公開しません。エラーだけでは撮影・保存用MP4の生成は自動停止しないため、アプリの`停止`で終了処理と写真保存を行います。

## 配信終了時の端末保存

配信開始にはカメラ・マイクに加えて、写真ライブラリへの追加権限が必要です。写真への追加を拒否した場合は配信を開始しません。設定アプリで許可してください。

撮影は背面カメラで縦向き1080pで行い、配信用HLSはH.264 High・720×1280・映像1.5 Mbps、AAC・64 kbps・44.1 kHz・モノラル、保存動画は上記のフルHD・HEVCで生成します。必要な撮影・保存設定に対応しない場合は、プレビュー・配信開始時、または保存用Writerの処理時にエラーになります。

停止すると両Writerの完了を待ち、写真へ自動保存します。写真保存はHTTP送信完了を待たずに始まり、画面ではHLSと写真保存それぞれの結果を確認できます。「保存しました」の表示後、写真アプリで映像・音声・向きを確認してください。

写真保存に失敗した完成MP4はApplication Supportの`LocalRecordings`に保持し、「未保存の動画を写真へ保存」から再試行できます。アプリ再起動後も未保存動画を表示します。写真保存成功後は作業用ファイルの削除を試み、削除に失敗しても再保存対象から外して重複保存を防ぎます。未完成の`.recording.mp4`は写真保存対象になりません。

バックグラウンド移行時も停止処理を行い、iOSが許す有限の実行時間で終了処理を保護します。時間切れ時は警告を表示します。継続的なバックグラウンド撮影を保証するサンプルではありません。完成済みMP4が未保存の場合は、アプリに戻って再試行します。

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

iOSアプリはiOS 26以上を対象とし、iOS 26 SDKを含むXcodeでビルドします。
Python 3.10以上を使います。追加パッケージのインストールは不要です。

### 同じネットワークで確認する

1. MacでHTTPサーバーを起動します。

   ```sh
   python3 server/server.py
   ```

2. Macのブラウザで`http://localhost:8080`を開きます。
3. MacとiPhoneを同じネットワークへ接続します。
4. `ios/iosdc2026HLSSample.xcodeproj`をXcodeで開き、アプリターゲットの`Signing & Capabilities`で自分のTeamを選択して、iPhone実機で実行します。起動時にカメラとマイクの権限を許可します。
5. サーバー起動時に表示される`http://<MacのIPアドレス>:8080`をiOSアプリの`Mac HTTP Server`へ入力し、`接続確認`を押します。ローカルネットワークへのアクセスを求められた場合は許可します。
6. `配信開始`を押して写真への追加も許可し、Macのブラウザで再生を確認します。音声を確認する場合はプレイヤーのミュートを解除します。
7. 停止後に`保存しました`を確認し、写真アプリで保存された動画を再生します。

macOSのファイアウォール確認が表示された場合は、Pythonからの受信接続を許可してください。iOS SimulatorからMac上のサーバーへの接続確認には`http://localhost:8080`を使用できます。カメラ撮影を含む配信・保存の動作確認にはiPhone実機を使用します。

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
| `GET` | `/streams/{streamId}/init.mp4`、`/streams/{streamId}/seg/{sequence}.m4s`、`/streams/{streamId}/playlist.m3u8` | HLSオブジェクトの配信 |

サーバーはPUTを一時ファイルへ書き込み、完了後に置換します。ブラウザが書き込み途中のplaylistやsegmentを取得しないためです。

`streamId`は英数字・`_`・`-`の1〜128文字、`sequence`は6桁の数字です。PUTには`Content-Length`が必要で、空の本文や32 MiBを超える本文は拒否します。GETの各パスはHEADにも対応し、ファイル配信は単一のbyte rangeに対応します。

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

`savesGeneratedMP4UsingPhotoKitQueue`は、実際のPhotosの変更ブロックまで実行する回帰テストです。
Simulatorで写真への追加が許可済みの場合だけ実行し、実機では実行しません。合成した1秒の動画をSimulatorの写真ライブラリへ追加します。
実行する場合はテスト専用Simulatorを起動し、次の権限設定後、上のテストコマンドにそのSimulatorのIDと`-parallel-testing-enabled NO`を指定します。

```sh
xcrun simctl privacy <SIMULATOR_ID> grant photos-add jp.co.hikarusato.iosdc2026HLSSample
```

写真保存の`performChanges`ブロックはPhotos独自のserial queueで呼ばれるため、`@Sendable`としてMainActorの継承を防ぎます。保存後のUI・状態更新はMainActorへ戻ります。

Mac HTTPサーバーのテストは次のコマンドで実行します。

```sh
python3 -m unittest discover -s server/tests -v
```

## 注意

Mac HTTPサーバーはデモ専用です。認証、TLS、アクセス制御、保存容量の管理は実装していません。通常は同一ネットワーク内だけで使用し、ngrokを使う場合も上記の会場デモ中だけ一時的に公開してください。

ネイティブHLSに対応しないブラウザでは同梱したhls.js v1.6.16を使用します。ライセンスは`server/static/vendor/LICENSE.hls.js.txt`を参照してください。
