#!/usr/bin/env node
/**
 * scripts/generate-all-snippet-mirror.js
 *
 * Generates mirrors for ALL .docx files under /snippets.
 *
 * Features:
 * - Default output format: gfm (Markdown)
 * - format=<gfm|markdown|html>
 * - --clean: deletes ONLY subfolders within snippets-mirror/ (keeps files like README.md at root)
 * - Cleans up stale mirrors (deletes mirrors with no corresponding .docx source)
 *
 * Usage (repo root):
 *   node scripts/generate-all-snippet-mirror.js
 *   node scripts/generate-all-snippet-mirror.js format=html
 *   node scripts/generate-all-snippet-mirror.js --clean
 *   node scripts/generate-all-snippet-mirror.js --debug-xml
 */

import fs from 'node:fs';
import path from 'node:path';
import {generateSnippetMirror} from './generate-snippet-mirror.js';

const DEFAULTS={format:'gfm',clean:false,debugXml:false};

function parseCliArgs(argv) {
  const initial={format:DEFAULTS.format,clean:DEFAULTS.clean,debugXml:DEFAULTS.debugXml};

  return argv.slice(2).reduce((acc,arg)=>{
    if (arg === '--clean') return {...acc,clean:true};
    if (arg === '--debug-xml') return {...acc,debugXml:true};
    if (arg.startsWith('format=')) {
      const format=arg.slice('format='.length).trim().toLowerCase();
      return {...acc,format:format || acc.format};
    }
    return acc;
  },initial);
}

function isHtmlFormat(format) {
  return (format || '').toLowerCase() === 'html';
}

function outputExtensionFor(format) {
  return isHtmlFormat(format) ? '.html' : '.md';
}

function normalizeFormat(format) {
  const f=(format || '').toLowerCase();
  if (f === 'md') return 'gfm';
  if (f === 'markdown') return 'gfm';
  return f || 'gfm';
}

function walkFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const entries=fs.readdirSync(dir,{withFileTypes:true});
  return entries.flatMap(entry=>{
    const full=path.join(dir,entry.name);
    if (entry.isDirectory()) return walkFiles(full);
    if (entry.isFile()) return [full];
    return [];
  });
}

function listDocxFilesUnderSnippets() {
  return walkFiles('snippets').filter(p=>p.toLowerCase().endsWith('.docx'));
}

function mirrorPathForDocx(docxPath,format) {
  const ext=outputExtensionFor(format);
  const normalized=docxPath.replace(/\\/g,'/');
  const rel=normalized.slice('snippets/'.length).replace(/\.docx$/i,ext);
  return path.join('snippets-mirror',...rel.split('/'));
}

function listMirrorFiles(format) {
  const ext=outputExtensionFor(format).toLowerCase();
  return walkFiles('snippets-mirror').filter(p=>p.toLowerCase().endsWith(ext));
}

function cleanMirrorOutput() {
  const root='snippets-mirror';
  if (!fs.existsSync(root)) return;

  // Delete only subfolders, keep files directly within snippets-mirror (e.g., README.md).
  fs.readdirSync(root,{withFileTypes:true})
    .filter(entry=>entry.isDirectory())
    .forEach(entry=>{
      fs.rmSync(path.join(root,entry.name),{recursive:true,force:true});
    });
}

function removeStaleMirrors({docxFiles,format}) {
  const expected=new Set(
    docxFiles.map(docx=>path.resolve(mirrorPathForDocx(docx,format)))
  );

  const mirrors=listMirrorFiles(format)
    .map(p=>path.resolve(p));

  mirrors.forEach(mirror=>{
    // Always keep root README.md (and any other root files); stale cleanup only for mirrors.
    const rel=path.relative(path.resolve('snippets-mirror'),mirror);
    if (!rel || rel.startsWith('..')) return;
    if (!rel.includes(path.sep)) return; // file directly under snippets-mirror/

    if (!expected.has(mirror)) {
      fs.rmSync(mirror,{force:true});
    }
  });

  // Remove now-empty directories (but never remove snippets-mirror itself).
  const allDirs=walkFiles('snippets-mirror')
    .map(p=>path.dirname(p))
    .filter((v,i,a)=>a.indexOf(v) === i)
    .sort((a,b)=>b.length-a.length);

  allDirs.forEach(d=>{
    if (d === path.resolve('snippets-mirror')) return;
    try {
      if (fs.existsSync(d) && fs.readdirSync(d).length === 0) {
        fs.rmdirSync(d);
      }
    } catch {}
  });
}

async function generateAllMirrors({format,debugXml}) {
  const docxFiles=listDocxFilesUnderSnippets();
  const failures=[];

  for (const docxPath of docxFiles) {
    try {
      await generateSnippetMirror({docxPath,format,debugXml});
    } catch (err) {
      failures.push({docxPath,error:err?.message || String(err)});
    }
  }

  removeStaleMirrors({docxFiles,format});

  return {docxFiles,failures};
}

async function main() {
  const args=parseCliArgs(process.argv);
  const format=normalizeFormat(args.format);

  if (!fs.existsSync('snippets')) {
    console.error('Expected a "snippets/" folder in repo root.');
    process.exit(2);
  }

  fs.mkdirSync('snippets-mirror',{recursive:true});

  if (args.clean) {
    cleanMirrorOutput();
  }

  const {docxFiles,failures}=await generateAllMirrors({format,debugXml:args.debugXml});

  console.log(`Processed ${docxFiles.length} .docx file(s).`);
  if (failures.length > 0) {
    console.error(`Failures (${failures.length}):`);
    failures.forEach(f=>{
      console.error(`- ${f.docxPath}: ${f.error}`);
    });
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(err=>{
    console.error(err?.stack || String(err));
    process.exit(1);
  });
}
