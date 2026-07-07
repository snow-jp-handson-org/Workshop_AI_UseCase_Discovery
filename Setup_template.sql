-- ==========================================================================
-- 概要: Cortex Agent + HTMLレポート生成基盤 テンプレートセットアップスクリプト
-- 目的: 変数を変更するだけで任意のワークショップ環境に展開可能
-- 使い方:
--   1. Section 0 の変数を環境に合わせて変更する
--   2. スクリプト全体を順番に実行する
-- ==========================================================================
-- Co-authored with CoCo

-- ##########################################################################
-- Section 0: 変数定義 (ここだけ変更すれば環境を切り替え可能)
-- ##########################################################################

SET DB_NAME            = 'CORPORATE_REPORT_ANALYZE';   -- メインデータベース名
SET SEARCH_SCHEMA      = 'REPORT_SEARCH_SCHEMA';       -- 検索・Agent用スキーマ名
SET OUTPUT_SCHEMA      = 'ANALYZE';                    -- HTML出力・Streamlit用スキーマ名
SET WAREHOUSE          = 'COMPUTE_WH';                 -- 実行ウェアハウス名
SET COMPUTE_POOL       = 'SYSTEM_COMPUTE_POOL_CPU';    -- Streamlitコンテナ用コンピュートプール
SET AGENT_NAME         = 'REPORT_ANALYSIS_AGENT';      -- Cortex Agent名
SET SEARCH_SERVICE     = 'REPORT_SEARCH_SERVICE';      -- Cortex Search Service名
SET GIT_REPO           = 'WORKSHOP_AI_USECASE_REPO';   -- Git Repositoryオブジェクト名
SET GIT_ORIGIN         = 'https://github.com/snow-jp-handson-org/Workshop_AI_UseCase_Discovery.git';
SET REPORTS_BRANCH_PATH = 'branches/main/Reports/Constract_Report/'; -- PDFのGitパス
SET APP_BRANCH_PATH    = 'branches/main/html_viewer/';               -- StreamlitアプリのGitパス

-- ##########################################################################
-- Section 1: データベース・スキーマ・ステージの作成
-- ##########################################################################

CREATE OR REPLACE DATABASE IDENTIFIER($DB_NAME);
USE DATABASE IDENTIFIER($DB_NAME);

CREATE OR REPLACE SCHEMA IDENTIFIER($SEARCH_SCHEMA);
CREATE OR REPLACE SCHEMA IDENTIFIER($OUTPUT_SCHEMA);

USE SCHEMA IDENTIFIER($SEARCH_SCHEMA);

-- PDFファイル格納用ステージ
CREATE OR REPLACE STAGE FILES
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Internal stage for PDF file storage';

USE SCHEMA IDENTIFIER($OUTPUT_SCHEMA);

-- Agent生成HTMLファイル格納用ステージ
CREATE OR REPLACE STAGE HTML_REPORTS
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Output HTML Files from Agent';

-- ##########################################################################
-- Section 2: Git連携
-- ##########################################################################

-- GitHub API連携用インテグレーション
CREATE OR REPLACE API INTEGRATION GIT_API_INTEGRATION
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/snow-jp-handson-org/')
  ENABLED = TRUE;

-- Git Repositoryオブジェクトの作成
CREATE OR REPLACE GIT REPOSITORY IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.' || $GIT_REPO)
  API_INTEGRATION = GIT_API_INTEGRATION
  ORIGIN = $GIT_ORIGIN;

-- リポジトリの最新コードを取得
ALTER GIT REPOSITORY IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.' || $GIT_REPO) FETCH;

-- Git Repo から内部ステージへPDFをコピー
COPY FILES
  INTO @IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.FILES')
  FROM @IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.' || $GIT_REPO) || '/' || $REPORTS_BRANCH_PATH
  PATTERN = '.*\.pdf';

-- ##########################################################################
-- Section 3: Cortex Search Service
-- ##########################################################################

-- ※ Cortex Search Service は PDF取り込み後に以下を参考に別途作成してください
-- CREATE OR REPLACE CORTEX SEARCH SERVICE IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.' || $SEARCH_SERVICE)
--   ON CHUNK
--   ATTRIBUTES RELATIVE_PATH, INDEX
--   WAREHOUSE = IDENTIFIER($WAREHOUSE)
--   TARGET_LAG = '1 hour'
--   AS (
--     SELECT
--       c.VALUE::VARCHAR AS CHUNK,
--       RELATIVE_PATH,
--       INDEX
--     FROM DIRECTORY(@IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.FILES')),
--       TABLE(SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
--         SNOWFLAKE.CORTEX.PARSE_DOCUMENT(@IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.FILES'), RELATIVE_PATH, {'mode': 'LAYOUT'})['content']::VARCHAR,
--         'markdown', 2000, 400
--       )) c
--   );

-- ##########################################################################
-- Section 4: Custom Tool (DEPLOY_HTML_REPORT プロシージャ)
-- ##########################################################################

USE SCHEMA IDENTIFIER($SEARCH_SCHEMA);

CREATE TABLE IF NOT EXISTS IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.HTML_REPORT_METADATA') (
    REPORT_NAME VARCHAR NOT NULL,
    TITLE VARCHAR,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.DEPLOY_HTML_REPORT')(
    HTML_CONTENT VARCHAR,
    REPORT_NAME VARCHAR,
    TITLE VARCHAR
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
EXECUTE AS CALLER
AS '
import re

def main(session, html_content: str, report_name: str, title: str) -> str:
    # セッションからDB/スキーマを取得
    ctx = session.sql("SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()").collect()[0]
    db = ctx[0]
    schema = ctx[1]

    if not re.match(r''^[a-zA-Z0-9_]+$'', report_name):
        return "Error: report_name must contain only alphanumeric characters and underscores. Got: ''" + report_name + "''"

    if not html_content or len(html_content.strip()) < 10:
        return "Error: html_content is empty or too short."

    file_name = report_name + ".html"
    output_schema = db + ".ANALYZE"  -- HTML出力スキーマ (OUTPUT_SCHEMA固定参照)

    try:
        from snowflake.snowpark import Row
        tmp_table = db + "." + schema + "._TMP_HTML_DEPLOY"
        df = session.create_dataframe([Row(CONTENT=html_content)])
        df.write.mode("overwrite").save_as_table(tmp_table, table_type="temporary")

        copy_sql = (
            "COPY INTO @" + output_schema + ".HTML_REPORTS/" + file_name +
            " FROM " + tmp_table +
            " FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = NONE" +
            " COMPRESSION = NONE FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE)" +
            " OVERWRITE = TRUE SINGLE = TRUE MAX_FILE_SIZE = 268435456"
        )
        session.sql(copy_sql).collect()
        session.sql("DROP TABLE IF EXISTS " + tmp_table).collect()

        safe_rn = report_name.replace("''", "''''")
        safe_t = title.replace("''", "''''")
        meta_table = db + "." + schema + ".HTML_REPORT_METADATA"
        merge_sql = (
            "MERGE INTO " + meta_table + " AS target "
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
-- Section 5: Cortex Agent定義
-- ##########################################################################

CREATE OR REPLACE AGENT IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.' || $AGENT_NAME)
  COMMENT='REPORT_SEARCH_SERVICEを活用し、コーポレートレポートの中長期的な経営戦略・財務・ESG等を分析するCortex Agent。'
  PROFILE='{"display_name":"中長期レポート分析アシスタント","avatar":"SparklesAgentIcon","color":"green"}'
FROM SPECIFICATION $$
models:
  orchestration: "auto"
orchestration: {}
instructions:
  response: "あなたは中長期レポート分析の専門アシスタントです。REPORT_SEARCH_SERVICEに格納されたコーポレートレポート（統合報告書）を検索・分析し、中長期的な経営戦略、財務状況、ESG活動、事業ポートフォリオに関するユーザーの質問に日本語で回答します。 また、Snowflakeの公式ドキュメント（CKE）も検索可能です。Snowflakeの機能や技術的な質問に対しても回答できます。 回答時のルール： - 中長期的な視点で情報を整理し、トレンドや戦略の方向性を明確に示してください - 財務データや数値目標がある場合は具体的に引用してください - 複数のセクションから情報を統合し、体系的に分析結果を提示してください - 回答には参照元のレポートファイル名（RELATIVE_PATH）とページ位置（INDEX）を明記してください - Snowflakeドキュメントからの回答にはドキュメントタイトルとURLを明記してください - 分析の根拠が不十分な場合は、その旨を明示し、推測と事実を区別してください - 中期経営計画、財務目標、ESG目標などの定量的情報は表形式で整理して提示してください"
  orchestration: "ユーザーの質問に回答するために、適切なツールを選択してください。\n■ レポート分析（report_analysis_search）： - コーポレートレポート、統合報告書、中期経営計画、財務情報、ESG、事業ポートフォリオなどの質問に使用 - 経営戦略に関する質問では「中期経営計画」「ビジョン」「成長戦略」等のキーワードを活用 - 財務に関する質問では「売上」「営業利益」「ROE」「配当」等の具体的指標名で検索 - ESGに関する質問では「サステナビリティ」「環境」「ガバナンス」「人的資本」等で検索\n■ Snowflakeドキュメント検索（snowflake_docs_search）： - Snowflakeの機能、SQL構文、設定、ベストプラクティスなど技術的な質問に使用 - Snowflakeの製品機能や使い方に関する質問はこちらのツールを使用\n■ HTMLレポートデプロイ（deploy_html_report）： - 分析結果をHTMLレポートとして保存したい場合に使用 - ユーザーが「レポートを作成して」「HTMLで出力して」「ダッシュボードにまとめて」と依頼した場合に使用 - 【重要】HTMLレポートを作成する前に、必ずユーザーにファイル名（report_name）を確認してください - ユーザーがファイル名を指定するまで、deploy_html_reportツールを呼び出さないでください - report_nameは英数字とアンダースコアのみ使用可能です（日本語不可） - titleには日本語を使用できます\n分析的な質問には以下のアプローチを取ってください： 1. まず質問のテーマに関連する広範なキーワードで検索する 2. 必要に応じて追加の検索を行い、関連情報を網羅的に収集する 3. 収集した情報を統合し、中長期的な観点から分析的に回答する 4. 一度の検索で不十分な場合は、別の角度からのキーワードで再検索してください"
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
    search_service: "REPLACE_WITH_DB.REPLACE_WITH_SEARCH_SCHEMA.REPLACE_WITH_SEARCH_SERVICE"
    title_column: "RELATIVE_PATH"
  snowflake_docs_search:
    max_results: 1000
    search_service: "SNOWFLAKE_DOCUMENTATION.SHARED.CKE_SNOWFLAKE_DOCS_SERVICE"
    title_column: "DOCUMENT_TITLE"
  deploy_html_report:
    type: "procedure"
    identifier: "REPLACE_WITH_DB.REPLACE_WITH_SEARCH_SCHEMA.DEPLOY_HTML_REPORT"
    execution_environment:
      type: "warehouse"
      warehouse: "REPLACE_WITH_WAREHOUSE"
$$;
-- ※ Agent SPECIFICATION内はSET変数が使えないため、上記の REPLACE_WITH_* 部分を
--   Section 0 の変数値に合わせて手動で書き換えてください。

-- ##########################################################################
-- Section 6: HTML確認用Streamlitアプリ構築 (コンテナランタイム)
-- ##########################################################################

USE DATABASE IDENTIFIER($DB_NAME);
USE SCHEMA IDENTIFIER($OUTPUT_SCHEMA);

-- PyPIアクセス用External Access Integration
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION PYPI_ACCESS_INTEGRATION
  ALLOWED_NETWORK_RULES = (snowflake.external_access.pypi_rule)
  ENABLED = TRUE;

-- Streamlitアプリ用ステージ
CREATE OR REPLACE STAGE IDENTIFIER($DB_NAME || '.' || $OUTPUT_SCHEMA || '.HTML_VIEWER_STAGE')
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Gitリポジトリからアプリコードをコピー
COPY FILES
  INTO @IDENTIFIER($DB_NAME || '.' || $OUTPUT_SCHEMA || '.HTML_VIEWER_STAGE')
  FROM @IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.' || $GIT_REPO) || '/' || $APP_BRANCH_PATH;

-- Streamlitアプリの作成
CREATE OR REPLACE STREAMLIT IDENTIFIER($DB_NAME || '.' || $OUTPUT_SCHEMA || '.HTML_VIEWER')
  FROM @IDENTIFIER($DB_NAME || '.' || $OUTPUT_SCHEMA || '.HTML_VIEWER_STAGE')
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = IDENTIFIER($WAREHOUSE)
  COMPUTE_POOL = IDENTIFIER($COMPUTE_POOL)
  RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  EXTERNAL_ACCESS_INTEGRATIONS = (PYPI_ACCESS_INTEGRATION);

-- ##########################################################################
-- Section 7: 権限付与
-- ##########################################################################

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;
GRANT USAGE ON DATABASE IDENTIFIER($DB_NAME) TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA) TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA IDENTIFIER($DB_NAME || '.' || $OUTPUT_SCHEMA) TO ROLE SYSADMIN;
GRANT ALL ON STAGE IDENTIFIER($DB_NAME || '.' || $OUTPUT_SCHEMA || '.HTML_REPORTS') TO ROLE SYSADMIN;
GRANT ALL ON TABLE IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.HTML_REPORT_METADATA') TO ROLE SYSADMIN;
GRANT USAGE ON PROCEDURE IDENTIFIER($DB_NAME || '.' || $SEARCH_SCHEMA || '.DEPLOY_HTML_REPORT')(VARCHAR, VARCHAR, VARCHAR) TO ROLE SYSADMIN;
