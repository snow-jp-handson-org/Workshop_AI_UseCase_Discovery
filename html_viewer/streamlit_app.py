import streamlit as st
import re
from pathlib import Path
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="HTML Viewer", layout="wide")
st.title("HTML Viewer")

session = get_active_session()

STATIC_DIR = Path(__file__).parent / "static"

CDN_MAP = {
    "chart.js": "chart.umd.min.js",
}

if "refresh_counter" not in st.session_state:
    st.session_state.refresh_counter = 0

col1, col2 = st.columns([6, 1])
with col2:
    if st.button("🔄 更新"):
        st.session_state.refresh_counter += 1
        st.cache_data.clear()
        st.rerun()

_ = st.session_state.refresh_counter

stages_df = session.sql("SHOW STAGES IN CORPORATE_REPORT_ANALYZE.ANALYZE").collect()
stage_names = [row["name"] for row in stages_df]

if not stage_names:
    st.warning("ステージが見つかりません。")
    st.stop()

selected_stage = st.selectbox("ステージを選択", stage_names)

files_df = session.sql(f"LIST @CORPORATE_REPORT_ANALYZE.ANALYZE.{selected_stage}").collect()
html_files = [row["name"] for row in files_df if row["name"].endswith(".html")]

if not html_files:
    st.warning("選択したステージにHTMLファイルがありません。")
    st.stop()

display_names = [f.split("/")[-1] for f in html_files]
selected_idx = st.selectbox("HTMLファイルを選択", range(len(display_names)), format_func=lambda i: display_names[i])
selected_file = html_files[selected_idx]

stage_path = f"@CORPORATE_REPORT_ANALYZE.ANALYZE.{selected_stage}"

file_name = selected_file.split("/")[-1]

with session.file.get_stream(f"{stage_path}/{file_name}") as f:
    html_content = f.read().decode("utf-8")


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


if html_content:
    st.download_button(
        label="📥 HTMLをダウンロード",
        data=html_content,
        file_name=file_name,
        mime="text/html",
    )

    html_rendered = inline_external_scripts(html_content)
    st.html(html_rendered)
else:
    st.error(f"ファイルの読み込みに失敗しました: {file_name}")
