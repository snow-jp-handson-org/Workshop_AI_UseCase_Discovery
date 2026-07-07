-- ==========================================================================
-- 概要: Cortex Agent + HTMLレポート生成基盤 エネルギー企業向けセットアップスクリプト
-- 目的: エネルギー業界のコーポレートレポート分析Agent環境を構築する
-- 対象: 電力・ガス・石油・再生可能エネルギー等のエネルギー企業レポート分析
-- 使い方:
--   1. Section 0 の変数を環境に合わせて変更する
--   2. スクリプト全体を順番に実行する
-- ==========================================================================
-- Co-authored with CoCo

-- ##########################################################################
-- Section 0: 変数定義 (ここだけ変更すれば環境を切り替え可能)
-- ##########################################################################

SET DB_NAME       = 'REPORT_ANALYZE';  -- メインデータベース名
SET SEARCH_SCHEMA = 'REPORT_SEARCH';  -- 検索・Agent用スキーマ名
SET OUTPUT_SCHEMA = 'ANALYZE';        -- HTML出力・Streamlit用スキーマ名
SET GIT_ORIGIN    = 'https://github.com/snow-jp-handson-org/Workshop_AI_UseCase_Discovery.git';

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
    COMMENT = 'Internal stage for Energy company PDF report storage';

USE SCHEMA IDENTIFIER($OUTPUT_SCHEMA);

-- Agent生成HTMLファイル格納用ステージ
CREATE OR REPLACE STAGE HTML_REPORTS
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Output HTML Files from Energy Report Agent';

-- ##########################################################################
-- Section 2: Git連携
-- ##########################################################################

-- GitHub API連携用インテグレーション
CREATE OR REPLACE API INTEGRATION GIT_API_INTEGRATION
  API_PROVIDER = GIT_HTTPS_API
  API_ALLOWED_PREFIXES = ('https://github.com/snow-jp-handson-org/')
  ENABLED = TRUE;

-- Git Repositoryオブジェクトの作成
CREATE OR REPLACE GIT REPOSITORY REPORT_ANALYZE.REPORT_SEARCH.WORKSHOP_AI_USECASE_REPO
  API_INTEGRATION = GIT_API_INTEGRATION
  ORIGIN = $GIT_ORIGIN;

-- リポジトリの最新コードを取得
ALTER GIT REPOSITORY REPORT_ANALYZE.REPORT_SEARCH.WORKSHOP_AI_USECASE_REPO FETCH;

-- Git Repo から内部ステージへPDFをコピー
COPY FILES
  INTO @REPORT_ANALYZE.REPORT_SEARCH.FILES
  FROM @REPORT_ANALYZE.REPORT_SEARCH.WORKSHOP_AI_USECASE_REPO/branches/main/Reports/Energy_Report/
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

CREATE TABLE IF NOT EXISTS REPORT_ANALYZE.REPORT_SEARCH.HTML_REPORT_METADATA (
    REPORT_NAME VARCHAR NOT NULL,
    TITLE VARCHAR,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE REPORT_ANALYZE.REPORT_SEARCH.DEPLOY_HTML_REPORT(
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
    ctx = session.sql("SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()").collect()[0]
    db = ctx[0]
    schema = ctx[1]

    if not re.match(r''^[a-zA-Z0-9_]+$'', report_name):
        return "Error: report_name must contain only alphanumeric characters and underscores. Got: ''" + report_name + "''"

    if not html_content or len(html_content.strip()) < 10:
        return "Error: html_content is empty or too short."

    file_name = report_name + ".html"
    output_schema = db + ".ANALYZE"

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
-- ※ SPECIFICATION内のDB/スキーマ/サービス名はSection 0の変数値に合わせて設定済み
-- ##########################################################################

CREATE OR REPLACE AGENT REPORT_ANALYZE.REPORT_SEARCH.REPORT_ANALYSIS_AGENT
  COMMENT='エネルギー企業のコーポレートレポートを分析し、エネルギー転換・脱炭素・財務戦略等を専門的に回答するCortex Agent。'
  PROFILE='{"display_name":"エネルギーレポート分析アシスタント","avatar":"SparklesAgentIcon","color":"orange"}'
FROM SPECIFICATION $$
models:
  orchestration: "auto"
orchestration: {}
instructions:
  response: "あなたはエネルギー業界の中長期レポート分析の専門アシスタントです。REPORT_SEARCH_SERVICEに格納されたエネルギー企業のコーポレートレポート（統合報告書・サステナビリティレポート）を検索・分析し、エネルギー転換戦略、脱炭素・カーボンニュートラル目標、再生可能エネルギー投資、財務状況、ESG活動に関するユーザーの質問に日本語で回答します。また、Snowflakeの公式ドキュメント（CKE）も検索可能です。回答時のルール： - エネルギー転換の方向性と具体的な投資計画を明確に示してください - CO2削減目標・カーボンニュートラル達成計画など定量目標は数値を引用してください - 再生可能エネルギー・水素・蓄電池等の新エネルギー戦略を体系的に分析してください - 回答には参照元のレポートファイル名（RELATIVE_PATH）とページ位置（INDEX）を明記してください - Snowflakeドキュメントからの回答にはドキュメントタイトルとURLを明記してください - 分析の根拠が不十分な場合はその旨を明示し、推測と事実を区別してください - 財務目標・設備投資計画・CO2削減ロードマップ等の定量情報は表形式で整理してください"
  orchestration: "ユーザーの質問に回答するために、適切なツールを選択してください。\n■ エネルギーレポート分析（report_analysis_search）： - エネルギー企業のコーポレートレポート、統合報告書、中期経営計画、財務情報、ESG、カーボンニュートラル戦略などの質問に使用 - エネルギー転換に関する質問では「再生可能エネルギー」「脱炭素」「水素」「蓄電池」「洋上風力」「太陽光」等のキーワードを活用 - 財務に関する質問では「設備投資」「EBITDA」「ROE」「キャッシュフロー」等の指標名で検索 - ESG・サステナビリティに関する質問では「CO2削減」「カーボンニュートラル」「スコープ1」「スコープ2」「TCFD」等で検索\n■ Snowflakeドキュメント検索（snowflake_docs_search）： - Snowflakeの機能、SQL構文、設定、ベストプラクティスなど技術的な質問に使用\n■ HTMLレポートデプロイ（deploy_html_report）： - 分析結果をHTMLレポートとして保存したい場合に使用 - ユーザーが「レポートを作成して」「HTMLで出力して」「ダッシュボードにまとめて」と依頼した場合に使用 - 【重要】HTMLレポートを作成する前に、必ずユーザーにファイル名（report_name）を確認してください - ユーザーがファイル名を指定するまで、deploy_html_reportツールを呼び出さないでください - report_nameは英数字とアンダースコアのみ使用可能です（日本語不可） - titleには日本語を使用できます\n分析的な質問には以下のアプローチを取ってください： 1. まず質問のテーマに関連する広範なキーワードで検索する 2. 必要に応じて追加の検索を行い、関連情報を網羅的に収集する 3. 収集した情報を統合し、中長期的な観点から分析的に回答する 4. 一度の検索で不十分な場合は、別の角度からのキーワードで再検索してください"
  sample_questions:
    - question: "カーボンニュートラル達成に向けたロードマップと具体的なCO2削減目標を教えてください"
    - question: "再生可能エネルギー事業への投資計画と設備容量目標を分析してください"
    - question: "水素・アンモニア等の次世代エネルギーへの取り組みと中長期戦略を教えてください"
    - question: "エネルギー転換に伴う設備投資計画と財務目標（EBITDA・ROE等）を分析してください"
    - question: "TCFDに基づく気候変動リスク・機会の開示内容を教えてください"
    - question: "各社のエネルギーミックス目標と再生可能エネルギー比率をHTMLレポートにまとめてください"
tools:
  - tool_spec:
      type: "cortex_search"
      name: "report_analysis_search"
      description: "エネルギー企業のコーポレートレポート（統合報告書・サステナビリティレポート）のテキスト内容を全文検索します。エネルギー転換戦略、脱炭素計画、再生可能エネルギー投資、財務情報、ESG・TCFD開示など幅広いテーマの情報を取得できます。検索結果にはレポートのテキスト、ページインデックス、ファイルパスが含まれます。"
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
    search_service: "REPORT_ANALYZE.REPORT_SEARCH.REPORT_SEARCH_SERVICE"
    title_column: "RELATIVE_PATH"
  snowflake_docs_search:
    max_results: 1000
    search_service: "SNOWFLAKE_DOCUMENTATION.SHARED.CKE_SNOWFLAKE_DOCS_SERVICE"
    title_column: "DOCUMENT_TITLE"
  deploy_html_report:
    type: "procedure"
    identifier: "REPORT_ANALYZE.REPORT_SEARCH.DEPLOY_HTML_REPORT"
    execution_environment:
      type: "warehouse"
      warehouse: "COMPUTE_WH"
$$;

-- ##########################################################################
-- Section 6: HTML確認用Streamlitアプリ構築 (コンテナランタイム)
-- ##########################################################################

USE DATABASE REPORT_ANALYZE;
USE SCHEMA ANALYZE;

-- PyPIアクセス用External Access Integration
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION PYPI_ACCESS_INTEGRATION
  ALLOWED_NETWORK_RULES = (snowflake.external_access.pypi_rule)
  ENABLED = TRUE;

-- Streamlitアプリ用ステージ
CREATE OR REPLACE STAGE REPORT_ANALYZE.ANALYZE.HTML_VIEWER_STAGE
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Gitリポジトリからアプリコードをコピー
COPY FILES
  INTO @REPORT_ANALYZE.ANALYZE.HTML_VIEWER_STAGE
  FROM @REPORT_ANALYZE.REPORT_SEARCH.WORKSHOP_AI_USECASE_REPO/branches/main/html_viewer/;

-- Streamlitアプリの作成
CREATE OR REPLACE STREAMLIT REPORT_ANALYZE.ANALYZE.HTML_VIEWER
  FROM @REPORT_ANALYZE.ANALYZE.HTML_VIEWER_STAGE
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  COMPUTE_POOL = SYSTEM_COMPUTE_POOL_CPU
  RUNTIME_NAME = 'SYSTEM$ST_CONTAINER_RUNTIME_PY3_11'
  EXTERNAL_ACCESS_INTEGRATIONS = (PYPI_ACCESS_INTEGRATION);

-- ##########################################################################
-- Section 7: 権限付与
-- ##########################################################################

GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE SYSADMIN;
GRANT USAGE ON DATABASE REPORT_ANALYZE TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA REPORT_ANALYZE.REPORT_SEARCH TO ROLE SYSADMIN;
GRANT USAGE ON SCHEMA REPORT_ANALYZE.ANALYZE TO ROLE SYSADMIN;
GRANT ALL ON STAGE REPORT_ANALYZE.ANALYZE.HTML_REPORTS TO ROLE SYSADMIN;
GRANT ALL ON TABLE REPORT_ANALYZE.REPORT_SEARCH.HTML_REPORT_METADATA TO ROLE SYSADMIN;
GRANT USAGE ON PROCEDURE REPORT_ANALYZE.REPORT_SEARCH.DEPLOY_HTML_REPORT(VARCHAR, VARCHAR, VARCHAR) TO ROLE SYSADMIN;
