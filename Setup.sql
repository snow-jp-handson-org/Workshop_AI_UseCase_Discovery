-- ==========================================================================
-- 概要: Cortex Agent + HTMLレポート生成基盤の環境構築スクリプト
-- 目的: コーポレートレポート分析Agentが使用するDB/スキーマ/ステージ/
--       カスタムツール(ストアドプロシージャ)/Agent定義/Streamlitアプリを
--       一括セットアップする
-- ==========================================================================
-- Co-authored with CoCo

-- ##########################################################################
-- Section 1: データベース・スキーマ・ステージの作成
-- ##########################################################################

-- レポート分析専用データベースの作成
CREATE OR REPLACE DATABASE CORPORATE_REPORT_ANALYZE;
USE DATABASE CORPORATE_REPORT_ANALYZE;

-- レポート検索用スキーマの作成
CREATE SCHEMA REPORT_SEARCH_SCHEMA;
USE SCHEMA REPORT_SEARCH_SCHEMA;

-- レポートPDFファイル格納用ステージ (Directory Table有効)
CREATE OR REPLACE STAGE FILES
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')   -- Snowflake管理の暗号化方式
    DIRECTORY = (ENABLE = TRUE)             -- ファイル一覧の自動メタデータ管理
    COMMENT = 'Internal stage for file storage';

-- HTML出力用スキーマの作成
CREATE OR REPLACE SCHEMA ANALYZE;
USE SCHEMA ANALYZE;

-- Agent生成HTMLファイル格納用ステージ (Directory Table有効)
CREATE OR REPLACE STAGE HTML_REPORTS
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Output HTML Files';


-- GitHub API連携用インテグレーション (Gitリポジトリへの接続許可)
CREATE OR REPLACE API INTEGRATION GIT_API_INTEGRATION
  API_PROVIDER = GIT_HTTPS_API                                      -- HTTPS経由のGit接続
  API_ALLOWED_PREFIXES = ('https://github.com/snow-jp-handson-org/') -- 許可するGitHubオーガニゼーション
  ENABLED = TRUE;

-- Gitリポジトリオブジェクトの作成 (Streamlitコード取得元)
CREATE OR REPLACE GIT REPOSITORY CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.WORKSHOP_AI_USECASE_REPO
  API_INTEGRATION = GIT_API_INTEGRATION
  ORIGIN = 'https://github.com/snow-jp-handson-org/Workshop_AI_UseCase_Discovery.git';

-- リポジトリの最新コードを取得
ALTER GIT REPOSITORY CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.WORKSHOP_AI_USECASE_REPO FETCH;

-- =========================
-- 2. Git Repo から内部ステージへファイルをコピー
-- =========================
COPY FILES
  INTO @CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.FILES
  FROM @CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.WORKSHOP_AI_USECASE_REPO/branches/main/Reports/Constract_Report/
  PATTERN = '.*\.pdf';
  

-- ##########################################################################
-- Section 2: 手動セットアップ手順 (UIまたは別途実行)
-- ##########################################################################

-- Cortex Search Serviceを作成
-- (Option : Snowflake Document CKEをインストール)

-- ##########################################################################
-- Section 3: Custom Tool - HTMLレポートデプロイ用ストアドプロシージャ
-- ##########################################################################

-- スキーマ切り替え
USE SCHEMA REPORT_SEARCH_SCHEMA;

-- レポートメタデータ管理テーブル (レポート名・タイトルを保持)
CREATE TABLE IF NOT EXISTS CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.HTML_REPORT_METADATA (
    REPORT_NAME VARCHAR NOT NULL,   -- ファイル識別子 (英数字+アンダースコアのみ)
    TITLE VARCHAR,                  -- 表示用タイトル (日本語可)
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()  -- 作成/更新日時
);

-- Agentが呼び出すカスタムツール本体 (PROCEDURE)
-- 機能: HTMLコンテンツを一時テーブル経由でステージにCOPY INTOし、メタデータテーブルにUPSERT
CREATE OR REPLACE PROCEDURE CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.DEPLOY_HTML_REPORT(
    HTML_CONTENT VARCHAR,   -- 保存するHTML文字列
    REPORT_NAME VARCHAR,    -- ファイル名 (拡張子不要, 英数字_のみ)
    TITLE VARCHAR           -- レポート表示タイトル
)
RETURNS VARCHAR             -- 実行結果メッセージ
LANGUAGE PYTHON             -- Python言語で記述
RUNTIME_VERSION = '3.11'    -- Python 3.11ランタイム
PACKAGES = ('snowflake-snowpark-python')  -- Snowpark依存パッケージ
HANDLER = 'main'            -- エントリポイント関数名
EXECUTE AS CALLER           -- 呼び出し元ユーザーの権限で実行
AS '
import re

def main(session, html_content: str, report_name: str, title: str) -> str:
    if not re.match(r''^[a-zA-Z0-9_]+$'', report_name):
        return "Error: report_name must contain only alphanumeric characters and underscores. Got: ''" + report_name + "''"

    if not html_content or len(html_content.strip()) < 10:
        return "Error: html_content is empty or too short."

    file_name = report_name + ".html"

    try:
        from snowflake.snowpark import Row
        df = session.create_dataframe([Row(CONTENT=html_content)])
        df.write.mode("overwrite").save_as_table(
            "CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA._TMP_HTML_DEPLOY",
            table_type="temporary"
        )

        copy_sql = (
            "COPY INTO @CORPORATE_REPORT_ANALYZE.ANALYZE.HTML_REPORTS/" + file_name +
            " FROM CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA._TMP_HTML_DEPLOY" +
            " FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = NONE" +
            " COMPRESSION = NONE FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE)" +
            " OVERWRITE = TRUE SINGLE = TRUE MAX_FILE_SIZE = 268435456"
        )
        session.sql(copy_sql).collect()

        session.sql("DROP TABLE IF EXISTS CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA._TMP_HTML_DEPLOY").collect()

        safe_rn = report_name.replace("''", "''''")
        safe_t = title.replace("''", "''''")
        merge_sql = (
            "MERGE INTO CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.HTML_REPORT_METADATA AS target "
            "USING (SELECT ''" + safe_rn + "'' AS REPORT_NAME, ''" + safe_t + "'' AS TITLE) AS source "
            "ON target.REPORT_NAME = source.REPORT_NAME "
            "WHEN MATCHED THEN UPDATE SET TITLE = source.TITLE, CREATED_AT = CURRENT_TIMESTAMP() "
            "WHEN NOT MATCHED THEN INSERT (REPORT_NAME, TITLE) VALUES (source.REPORT_NAME, source.TITLE)"
        )
        session.sql(merge_sql).collect()

        return "SUCCESS: Report ''" + title + "'' saved as " + file_name + " (" + str(len(html_content)) + " chars)."

    except Exception as e:
        return "Error deploying report: " + str(e)
';

-- ##########################################################################
-- Section 4: Cortex Agent定義 (CREATE AGENT)
-- ##########################################################################

-- Cortex Agentを作成 with Snowflake CoCo
-- Tool : 上記のCortex Search 2つ, Custom Tool

-- 以下はAgent仕様 (YAML形式のSPECIFICATION)
-- models.orchestration    : LLMモデル選択 ("auto"で最適モデル自動選定)
-- instructions.response   : Agentの応答ルール
-- instructions.orchestration : ツール選択のガイドライン
-- tools                   : Agentが使用可能なツール一覧
-- tool_resources          : 各ツールの接続先やパラメータ

CREATE OR REPLACE AGENT CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.REPORT_ANALYSIS_AGENT
  COMMENT='REPORT_SEARCH_SERVICEを活用し、コーポレートレポートの中長期的な経営戦略・財務・ESG等を分析するCortex Agent。'
  PROFILE='{"display_name":"中長期レポート分析アシスタント","avatar":"SparklesAgentIcon","color":"green"}'
FROM SPECIFICATION $$
models:
  orchestration: "auto"
orchestration: {}
instructions:
  response: "あなたは中長期レポート分析の専門アシスタントです。REPORT_SEARCH_SERVICEに格納されたコーポレートレポート（統合報告書）を検索・分析し、中長期的な経営戦略、財務状況、ESG活動、事業ポートフォリオに関するユーザーの質問に日本語で回答します。 また、Snowflakeの公式ドキュメント（CKE）も検索可能です。Snowflakeの機能や技術的な質問に対しても回答できます。 回答時のルール： - 中長期的な視点で情報を整理し、トレンドや戦略の方向性を明確に示してください - 財務データや数値目標がある場合は具体的に引用してください - 複数のセクションから情報を統合し、体系的に分析結果を提示してください - 回答には参照元のレポートファイル名（RELATIVE_PATH）とページ位置（INDEX）を明記してください - Snowflakeドキュメントからの回答にはドキュメントタイトルとURLを明記してください - 分析の根拠が不十分な場合は、その旨を明示し、推測と事実を区別してください - 中期経営計画、財務目標、ESG目標などの定量的情報は表形式で整理して提示してください"
  orchestration: "ユーザーの質問に回答するために、適切なツールを選択してください。\n■ レポート分析（report_analysis_search）： - コーポレートレポート、統合報告書、中期経営計画、財務情報、ESG、事業ポートフォリオなどの質問に使用 - 経営戦略に関する質問では「中期経営計画」「ビジョン」「成長戦略」等のキーワードを活用 - 財務に関する質問では「売上」「営業利益」「ROE」「配当」等の具体的指標名で検索 - ESGに関する質問では「サステナビリティ」「環境」「ガバナンス」「人的資本」等で検索\n■ Snowflakeドキュメント検索（snowflake_docs_search）： - Snowflakeの機能、SQL構文、設定、ベストプラクティスなど技術的な質問に使用 - Snowflakeの製品機能や使い方に関する質問はこちらのツールを使用\n■ HTMLレポートデプロイ（deploy_html_report）： - 分析結果をHTMLレポートとして保存したい場合に使用 - ユーザーが「レポートを作成して」「HTMLで出力して」「ダッシュボードにまとめて」と依頼した場合に使用 - 【重要】HTMLレポートを作成する前に、必ずユーザーにファイル名（report_name）を確認してください。例：「レポートのファイル名を指定してください（英数字とアンダースコアのみ、例: ai_strategy_report）」 - ユーザーがファイル名を指定するまで、deploy_html_reportツールを呼び出さないでください - report_nameは英数字とアンダースコアのみ使用可能です（日本語不可） - titleには日本語を使用できます\n分析的な質問には以下のアプローチを取ってください： 1. まず質問のテーマに関連する広範なキーワードで検索する 2. 必要に応じて追加の検索を行い、関連情報を網羅的に収集する 3. 収集した情報を統合し、中長期的な観点から分析的に回答する 4. 一度の検索で不十分な場合は、別の角度からのキーワードで再検索してください"
  sample_questions:
    - question: "中期経営計画の主要な財務目標と達成状況を教えてください"
    - question: "ESG・サステナビリティに関する中長期目標と取り組みを分析してください"
    - question: "事業ポートフォリオの構成と今後の成長戦略について教えてください"
    - question: "資本政策や株主還元の方針について、過去からの変遷を含めて説明してください"
    - question: "SnowflakeのCortex Search Serviceの使い方を教えてください"
    - question: "中期経営計画の要点をHTMLレポートにまとめてください"
tools:
  - tool_spec:
      type: "cortex_search"
      name: "report_analysis_search"
      description: "コーポレートレポート（統合報告書）のテキスト内容を全文検索します。中長期経営戦略、財務情報、ESG活動、事業ポートフォリオ、ガバナンスなど幅広いテーマの情報を取得できます。検索結果にはレポートのテキスト、ページインデックス、ファイルパスが含まれます。"
  - tool_spec:
      type: "cortex_search"
      name: "snowflake_docs_search"
      description: "Snowflakeの公式ドキュメント（CKE: Cortex Knowledge Extension）を全文検索します。Snowflakeの機能、SQL構文、設定方法、アーキテクチャ、ベストプラクティスなどの技術情報を取得できます。検索結果にはドキュメントのチャンク、タイトル、ソースURLが含まれます。"
  - tool_spec:
      type: "web_search"
      name: "Web Search"
  - tool_spec:
      type: "generic"
      name: "deploy_html_report"
      description: "生成したHTMLレポートをSnowflakeステージに保存し、Streamlitアプリ（HTML Report Viewer）で閲覧可能にします。report_nameは英数字とアンダースコアのみ使用してください。"
      input_schema:
        type: "object"
        properties:
          html_content:
            type: "string"
            description: "保存するHTMLコンテンツ（完全なHTML文書）"
          report_name:
            type: "string"
            description: "レポートのファイル名（拡張子不要、英数字とアンダースコアのみ）"
          title:
            type: "string"
            description: "レポートの表示タイトル（日本語可）"
        required:
          - "html_content"
          - "report_name"
          - "title"
tool_resources:
  Web Search:
    max_results: 10
  report_analysis_search:
    max_results: 1000
    search_service: "CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.REPORT_SEARCH_SERVICE"
    title_column: "RELATIVE_PATH"
  snowflake_docs_search:
    max_results: 1000
    search_service: "SNOWFLAKE_DOCUMENTATION.SHARED.CKE_SNOWFLAKE_DOCS_SERVICE"
    title_column: "DOCUMENT_TITLE"
  deploy_html_report:
    type: "procedure"
    identifier: "CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.DEPLOY_HTML_REPORT"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
$$;

-- ##########################################################################
-- Section 5: HTML確認用Streamlitアプリ構築 (コンテナランタイム)
-- ##########################################################################

-- スキーマ切り替え
USE DATABASE CORPORATE_REPORT_ANALYZE;
USE SCHEMA ANALYZE;

-- PyPIアクセス用External Access Integration (pip install用)
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION PYPI_ACCESS_INTEGRATION
  ALLOWED_NETWORK_RULES = (snowflake.external_access.pypi_rule)
  ENABLED = TRUE;

-- Streamlitアプリ用ステージ
CREATE OR REPLACE STAGE CORPORATE_REPORT_ANALYZE.ANALYZE.HTML_VIEWER_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Gitリポジトリからアプリコードをコピー
COPY FILES
  INTO @CORPORATE_REPORT_ANALYZE.ANALYZE.HTML_VIEWER_STAGE
  FROM @CORPORATE_REPORT_ANALYZE.REPORT_SEARCH_SCHEMA.WORKSHOP_AI_USECASE_REPO/branches/main/html_viewer/;

-- Streamlitアプリの作成 (コンテナランタイム + バージョン付きステージ)
CREATE OR REPLACE STREAMLIT CORPORATE_REPORT_ANALYZE.ANALYZE.HTML_VIEWER
  FROM @CORPORATE_REPORT_ANALYZE.ANALYZE.HTML_VIEWER_STAGE
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = 'COMPUTE_WH'
  COMPUTE_POOL = 'SYSTEM_COMPUTE_POOL_CPU'
  RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  EXTERNAL_ACCESS_INTEGRATIONS = (PYPI_ACCESS_INTEGRATION);

-- ##########################################################################
-- ポイント・補足情報
-- ##########################################################################
--
-- [ポイント]
-- 1. ステージはDIRECTORY=TRUE指定でファイル一覧のメタデータ自動管理が有効
-- 2. DEPLOY_HTML_REPORTはステージ保存+テーブル保存の二重化構成
--    - ステージ: ファイルとしてのバックアップ
--    - テーブル: Streamlitアプリからの高速読み込み用
-- 3. Agent定義はコメントアウト状態 (UIから作成するか、コメント解除して実行)
-- 4. EXECUTE AS CALLERにより、呼び出し元ユーザーの権限で実行
-- 5. StreamlitはGitリポジトリ連携でコード管理 (FETCH実行で最新化)
-- 6. コンテナランタイム使用のためCOMPUTE_POOL指定が必須
--
-- [補足]
-- - Cortex Search Serviceは別途作成が必要 (PDF取り込み後に構築)
-- - CKE (Snowflakeドキュメント検索) はMarketplaceからインストール
-- - report_nameに日本語を使用するとファイル名エラーになるため英数字に制限
-- - HTML_CONTENTカラムはVARCHAR(最大16MB)のため、巨大HTMLは分割を検討
-- - MCP Serverを別途作成すると、CoWorkや外部MCPクライアントからも利用可能
-- - ALLOW_ALL_RULEは全ホスト許可のため、本番環境では対象を限定すること
-- - Git FETCHはStreamlitコード更新時に再�


-- Grant Cortex database role
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;