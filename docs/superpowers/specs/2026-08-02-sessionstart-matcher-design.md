# SessionStart matcher 追加設計

**Issue:** #18

## 目的

`handoff-check.sh`をClaude Codeの`SessionStart`イベントへ登録するとき、
引き継ぎを消費すべき`startup`と`clear`だけをClaude Code側でも選別する。
`resume`と`compact`ではフックプロセス自体を起動しない構成にする。

## 現状

- `install.sh`は`SessionStart:<command>`形式でmatcher無しのグループを登録している。
- `handoff-check.sh`は標準入力の`source`を読み、`startup`/`clear`以外をfail-closedで拒否している。
- `lib/settings-hooks.py`は登録済みコマンドを台帳へ記録し、コマンド単位で自分のフックを除去する。
- 既存の利用者グループ、特にmatcher付きグループは保持する契約になっている。

## 決定

`install.sh`が作るSessionStartグループに、次のmatcherを付ける。

```json
{
  "matcher": "startup|clear",
  "hooks": [
    {"type": "command", "command": "..."}
  ]
}
```

内部の`source`判定は削除しない。設定のmatcherは通常の発火経路を絞り、
スクリプト内部の判定は、直接実行・手動実行・将来の設定変更に対する防御層として残す。
`CTS_FORCE=1`による手動確認の挙動も維持する。

## インターフェース

`lib/settings-hooks.py install`へ、次のオプションを追加する。

```text
--matcher EVENT=REGEX
```

- `--matcher`はinstall時だけ指定でき、複数指定できる。
- `EVENT`と`REGEX`は空を許さず、同じイベントの重複指定は拒否する。
- 指定されたイベントは、同じinstall呼び出しのフック仕様にも存在しなければならない。
- 不正な指定は終了コード64とし、設定・台帳を書き換えない。
- matcherは台帳へ新しい形式で保存しない。既存の台帳が保持するコマンド文字列を自分のフックの識別子として使い、旧形式からの再インストールを自動移行する。

フック仕様の既存形式`EVENT:COMMAND`は変更しない。コマンドパスにコロンを含む環境との互換性を保つためである。

## 変更範囲

- `install.sh`: SessionStartのmatcher指定をsettings-hooks.pyへ渡す。
- `lib/settings-hooks.py`: matcherオプションを解析し、登録グループへ`matcher`を付ける。
- `test/test-install.sh`: matcher生成、冪等性、旧形式からの移行、不正引数を検証する。
- 既存の`test/test-uninstall.sh`: matcher付き自前グループから自分のエントリだけを外し、同居する利用者フックを残す契約を確認する。
- `README.md`、`skills/session-handoff/SKILL.md`、既存仕様書: 発火源と設定matcherの説明を実装へ合わせる。

## 互換性と安全性

- 既存設定のmatcher付き利用者グループは変更しない。
- matcher無しで過去に登録された自分のグループは、台帳のコマンド記録で除去して新matcher付きで登録し直す。
- アンインストールは従来どおりコマンド単位で行い、matcher付きグループを丸ごと削除しない。
- `resume`/`compact`を設定側で除外しても、内部判定は残るため、設定のmatcherだけを安全境界にしない。

## 検証

次を受け入れ条件とする。

1. 新規インストールのSessionStartグループが`matcher: startup|clear`を持つ。
2. 再インストールでSessionStartフックとmatcherが重複しない。
3. matcher付きの利用者フックが保持される。
4. matcher無しで登録済みの自前フックが、再インストールでmatcher付きへ移行する。
5. 不正なmatcher引数が設定・台帳を変更せず拒否される。
6. `handoff-check.sh`の既存発火源マトリクス（startup/clearのみ発火、resume/compact/未知は無出力）が変わらない。
7. 全テストが成功する。

## 採用しなかった案

- matcherを追加せず、スクリプト内部だけで制御する案: `resume`/`compact`でも不要なプロセス起動が発生し、設定上の意図が不明確になる。
- matcherだけに制御を移し、スクリプト内部の判定を削除する案: 直接実行や設定変更時のfail-closed防御を失う。
