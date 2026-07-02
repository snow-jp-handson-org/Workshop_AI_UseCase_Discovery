import streamlit as st
import os
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

stages_df = session.sql("SHOW STAGES IN CONSTRACT.PUBLIC").collect()
stage_names = [row["name"] for row in stages_df]

if not stage_names:
    st.warning("ステージが見つかりません。")
    st.stop()

selected_stage = st.selectbox("ステージを選択", stage_names)

files_df = session.sql(f"LIST @CONSTRACT.PUBLIC.{selected_stage}").collect()
html_files = [row["name"] for row in files_df if row["name"].endswith(".html")]

if not html_files:
    st.warning("選択したステージにHTMLファイルがありません。")
    st.stop()

display_names = [f.split("/")[-1] for f in html_files]
selected_idx = st.selectbox("HTMLファイルを選択", range(len(display_names)), format_func=lambda i: display_names[i])
selected_file = html_files[selected_idx]

stage_path = f"@CONSTRACT.PUBLIC.{selected_stage}"
local_dir = "/tmp/html_viewer"
os.makedirs(local_dir, exist_ok=True)

file_name = selected_file.split("/")[-1]
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

    st.download_button(
        label="📥 HTMLをダウンロード",
        data=html_content,
        file_name=file_name,
        mime="text/html",
    )

    html_rendered = inline_external_scripts(html_content)
    st.components.v1.html(html_rendered, height=5000, scrolling=True)
else:
    st.error(f"ファイルのダウンロードに失敗しました: {file_name}")
