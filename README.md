# 📁 Snippets Mirror

This directory contains **auto-generated, text-based mirrors** of the `.docx` snippet files located under the main `snippets/` folder of the repository.

These HTML (`.html`) mirrors are produced automatically during development so that Git can provide meaningful diffs and code reviews for content that would otherwise exist only inside binary `.docx` files.

> **Important**  
> The files in this folder are **generated**. They should **never** be manually edited.

---

## 🚫 Do Not Edit Files Here

All files in `snippets-mirror/` are **one-way artifacts** produced by scripts in the `scripts/` directory:

- `scripts/generate-snippet-mirror.js`
- `scripts/generate-all-snippet-mirrors.js`

Any manual modifications to files in this folder **will be overwritten** the next time the mirror generation runs (either manually or via Git hook).

If you want to update snippet content, **edit the corresponding `.docx` file** under `snippets/`

