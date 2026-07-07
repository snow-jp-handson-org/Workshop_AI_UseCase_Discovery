import streamlit as st
import os
import re
from pathlib import Path
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="HTML Viewer", layout="wide")
st.title("HTML Viewer")

session = get_active_session()

STATIC_DIR = Path(__file__).parent / "static"
CDN_MAP = {"chart.js": "chart.umd.min.js"}

# セッションのDB/スキーマをデフォルト値として取得（コンテナランタイム対応）
_ctx = session.sql("SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()").collect()[0]
DEFAULT_DB     = _ctx[0] or ""
DEFAULT_SCHEMA = _ctx[1] or ""

# session_state の初期化（更新ボタン後も選択値を保持）
if "sel_db"     not in st.session_state: st.session_state.sel_db     = DEFAULT_DB
if "sel_schema" not in st.session_state: st.session_state.sel_schema = DEFAULT_SCHEMA
if "sel_stage"  not in st.session_state: st.session_state.sel_stage  = None
if "sel_file"   not in st.session_state: st.session_state.sel_file   = None

# 更新ボタン（選択中の内容を維持したままステージ・ファイルリストを再取得）
col1, col2 = st.columns([6, 1])
with col2:
    if st.button("🔄 更新"):
        st.cache_data.clear()
        st.rerun()

# DB・スキーマ選択
db_rows  = session.sql("SHOW DATABASES").collect()
db_names = [row["name"] for row in db_rows]
db_idx   = db_names.index(st.session_state.sel_db) if st.session_state.sel_db in db_names else 0
selected_db = st.selectbox("データベースを選択", db_names, index=db_idx, key="sel_db")

schema_rows  = session.sql(f"SHOW SCHEMAS IN DATABASE {selected_db}").collect()
schema_names = [row["name"] for row in schema_rows]
schema_idx   = schema_names.index(st.session_state.sel_schema) if st.session_state.sel_schema in schema_names else 0
selected_schema = st.selectbox("スキーマを選択", schema_names, index=schema_idx, key="sel_schema")

# ステージ選択
stages_df   = session.sql(f"SHOW STAGES IN {selected_db}.{selected_schema}").collect()
stage_names = [row["name"] for row in stages_df]
if not stage_names:
    st.warning("ステージが見つかりません。")
    st.stop()
stage_idx    = stage_names.index(st.session_state.sel_stage) if st.session_state.sel_stage in stage_names else 0
selected_stage = st.selectbox("ステージを選択", stage_names, index=stage_idx, key="sel_stage")

# ファイル選択
files_df   = session.sql(f"LIST @{selected_db}.{selected_schema}.{selected_stage}").collect()
html_files = [row["name"] for row in files_df if row["name"].endswith(".html")]
if not html_files:
    st.warning("選択したステージにHTMLファイルがありません。")
    st.stop()

display_names = [f.split("/")[-1] for f in html_files]
file_idx = 0
if st.session_state.sel_file in display_names:
    file_idx = display_names.index(st.session_state.sel_file)
selected_idx = st.selectbox(
    "HTMLファイルを選択",
    range(len(display_names)),
    index=file_idx,
    format_func=lambda i: display_names[i],
    key="sel_file_idx",
)
selected_file = html_files[selected_idx]
st.session_state.sel_file = display_names[selected_idx]

# ファイル取得
stage_path = f"@{selected_db}.{selected_schema}.{selected_stage}"
local_dir  = "/tmp/html_viewer"
os.makedirs(local_dir, exist_ok=True)
file_name  = selected_file.split("/")[-1]
local_path = os.path.join(local_dir, file_name)
session.sql(f"GET {stage_path}/{file_name} file://{local_dir}/").collect()


@st.cache_data
def load_local_script(filename: str) -> str:
    path = STATIC_DIR / filename
    if path.exists():
        return path.read_text(encoding="utf-8")
    return ""


@st.cache_data
def inline_external_scripts(html: str) -> str:
    pattern = r'<script\s+src=["\']([^"\']+)["\'][^>]*>\s*</script>'
    def replace_script(match):
        url = match.group(1)
        for cdn_key, local_file in CDN_MAP.items():
            if cdn_key in url:
                content = load_local_script(local_file)
                if content:
                    return f"<script>{content}</script>"
        return match.group(0)
    return re.sub(pattern, replace_script, html)


if os.path.exists(local_path):
    with open(local_path, "r", encoding="utf-8") as f:
        html_content = f.read()

    import base64
    html_rendered = inline_external_scripts(html_content)
    b64 = base64.b64encode(html_rendered.encode("utf-8")).decode()

    col_dl, col_fs = st.columns(2)
    with col_dl:
        st.download_button(
            label="📥 HTMLをダウンロード",
            data=html_content,
            file_name=file_name,
            mime="text/html",
        )
    with col_fs:
        fullscreen_js = f"""
        <script>
        function openFullscreen() {{
            var b64 = "{b64}";
            var html = decodeURIComponent(escape(atob(b64)));
            var win = window.open("", "_blank");
            win.document.open("text/html", "replace");
            win.document.write('<meta charset="utf-8">' + html);
            win.document.close();
        }}
        </script>
        <button onclick="openFullscreen()" style="padding:0.5rem 1rem;border-radius:0.3rem;border:1px solid #ccc;cursor:pointer;">
        🖥️ 全画面で表示</button>
        """
        st.components.v1.html(fullscreen_js, height=50)

    st.components.v1.html(html_rendered, height=5000, scrolling=True)
else:
    st.error(f"ファイルのダウンロードに失敗しました: {file_name}")
