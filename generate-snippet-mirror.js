#!/usr/bin/env node
/**
 * scripts/generate-snippet-mirror.js
 *
 * Generates a text “mirror” (Markdown by default, or HTML) for a single .docx
 * under /snippets, writing the output to the parallel /snippets-mirror tree.
 *
 * Core features:
 * - Preprocess OOXML (word/document.xml) to inject field codes as sentinels:
 *     pre:  ==::
 *     post: ::==
 * - Run pandoc on a temporary .docx with the mutated XML.
 * - Post-process pandoc output:
 *     - Markdown: convert sentinels to backticks, merge adjacent code spans
 *     - HTML:     convert sentinels to {{ }}, merge adjacent curly blocks
 *
 * Usage (repo root):
 *   node scripts/generate-snippet-mirror.js snippets/foo/bar.docx
 *   node scripts/generate-snippet-mirror.js snippets/foo/bar.docx format=html
 *   node scripts/generate-snippet-mirror.js snippets/foo/bar.docx --debug-xml
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';

import JSZip from 'jszip';
import {parseStringPromise,Builder} from 'xml2js';

const SENTINEL_PRE='==::';
const SENTINEL_POST='::==';

const DEFAULTS={format:'gfm',debugXml:false};

/**
 * parseCliArgs(argv)
 *
 * Supported:
 * - format=<gfm|markdown|html>
 * - --debug-xml
 *
 * Note: we intentionally do NOT support "format <val>" or "-f <val>" variants.
 */
function parseCliArgs(argv) {
  const initial={docxPath:null,format:DEFAULTS.format,debugXml:DEFAULTS.debugXml};

  return argv.slice(2).reduce((acc,arg)=>{
    if (!acc.docxPath && !arg.startsWith('-') && !arg.includes('format=')) {
      return {...acc,docxPath:arg};
    }
    if (arg === '--debug-xml') {
      return {...acc,debugXml:true};
    }
    if (arg.startsWith('format=')) {
      const format=arg.slice('format='.length).trim().toLowerCase();
      return {...acc,format:format || acc.format};
    }
    return acc;
  },initial);
}

function assertFileExists(filePath,label) {
  if (!filePath) {
    throw new Error(`Missing ${label}.`);
  }
  if (!fs.existsSync(filePath)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
}

function isHtmlFormat(format) {
  return format === 'html';
}

function outputExtensionFor(format) {
  return isHtmlFormat(format) ? '.html' : '.md';
}

function normalizeFormat(format) {
  // Accept a couple of friendly aliases.
  const f=(format || '').toLowerCase();
  if (f === 'md') return 'gfm';
  if (f === 'markdown') return 'gfm';
  return f || 'gfm';
}

function mirrorPathForDocx(docxPath,format) {
  const ext=outputExtensionFor(format);
  const normalized=docxPath.replace(/\\/g,'/');
  if (!normalized.toLowerCase().startsWith('snippets/')) {
    throw new Error(`Expected path under "snippets/". Got: ${docxPath}`);
  }
  const rel=normalized.slice('snippets/'.length).replace(/\.docx$/i,ext);
  return path.join('snippets-mirror',...rel.split('/'));
}

function ensureDirForFile(filePath) {
  fs.mkdirSync(path.dirname(filePath),{recursive:true});
}

/**
 * extractXmlElementTextContent(xmlElement)
 *
 * xml2js can represent text content as:
 * - a string
 * - an array of strings
 * - an object with "_" (less common with current options)
 *
 * This helper returns a best-effort string.
 */
function extractXmlElementTextContent(xmlElement) {
  if (xmlElement == null) return '';
  if (typeof xmlElement === 'string') return xmlElement;
  if (Array.isArray(xmlElement)) return xmlElement.map(extractXmlElementTextContent).join('');
  if (typeof xmlElement === 'object') {
    if (typeof xmlElement._ === 'string') return xmlElement._;
    return '';
  }
  return '';
}

/**
 * xmlTraversal helpers
 *
 * We treat the xml2js output as a generic tree:
 * - Objects: elementName -> childValue
 * - Arrays: sequences of children of the same elementName
 *
 * We only need to locate:
 * - w:instrText (field instructions / codes)
 * and inject additional w:t text nodes near it so pandoc will “see” it.
 */
function isObject(value) {
  return value && typeof value === 'object' && !Array.isArray(value);
}

function visitXml(value,visitor) {
  if (Array.isArray(value)) {
    value.forEach(v=>visitXml(v,visitor));
    return;
  }
  if (!isObject(value)) return;

  visitor(value);

  Object.values(value).forEach(v=>visitXml(v,visitor));
}

/**
 * takeFieldInstructionString(runLikeObject)
 *
 * Word field codes are often split across multiple <w:instrText> elements.
 * We concatenate any instrText values found within the run object.
 */
function takeFieldInstructionString(runLikeObject) {
  const instrTexts=[];
  visitXml(runLikeObject,(obj)=>{
    if (Object.prototype.hasOwnProperty.call(obj,'w:instrText')) {
      const v=obj['w:instrText'];
      if (Array.isArray(v)) {
        v.forEach(x=>{
          const s=extractXmlElementTextContent(x).trim();
          if (s) instrTexts.push(s);
        });
      } else {
        const s=extractXmlElementTextContent(v).trim();
        if (s) instrTexts.push(s);
      }
    }
  });
  return instrTexts.join(' ').replace(/\s+/g,' ').trim();
}

/**
 * injectFieldCodeSentinels(documentXmlString)
 *
 * - Parses XML into xml2js objects
 * - For each run (<w:r>), if it contains field instruction text, we inject
 *   additional visible text nodes (w:t) that bracket the field code.
 *
 * We DO NOT attempt to perfectly emulate Word field structure; we only need
 * pandoc to receive a docx where the field code becomes visible text.
 */
async function injectFieldCodeSentinels(documentXmlString) {
  const xml=await parseStringPromise(documentXmlString,{
    explicitArray:true,
    preserveChildrenOrder:true,
    explicitChildren:false,
    charsAsChildren:false
  });

  // Walk all objects and find any w:r arrays we can augment.
  visitXml(xml,(obj)=>{
    // Runs are usually stored as 'w:r': [ {...}, {...} ]
    if (!Object.prototype.hasOwnProperty.call(obj,'w:r')) return;

    const runs=obj['w:r'];
    if (!Array.isArray(runs)) return;

    runs.forEach(run=>{
      if (!isObject(run)) return;

      const instr=takeFieldInstructionString(run);
      if (!instr) return;

      // Represent the field code concisely by convention:
      // Example: "DOCPROPERTY  MyVar  \\* MERGEFORMAT" -> "DOCPROPERTY MyVar \\* MERGEFORMAT"
      const humanReadable=instr.replace(/\s+/g,' ').trim();

      // Insert a visible text node. We place it inside the run as an extra w:t.
      // Putting this at the end of the run tends to be stable for pandoc.
      const sentinelText=`${SENTINEL_PRE}${humanReadable}${SENTINEL_POST}`;

      // Ensure w:t exists as an array of strings/objects; append our sentinel.
      // Most OOXML uses w:t as array with one string item.
      if (!Object.prototype.hasOwnProperty.call(run,'w:t')) {
        run['w:t']=[sentinelText];
      } else if (Array.isArray(run['w:t'])) {
        run['w:t'].push(sentinelText);
      } else {
        run['w:t']=[run['w:t'],sentinelText];
      }
    });
  });

  const builder=new Builder({
    headless:true,
    renderOpts:{pretty:false},
    xmldec:{version:'1.0',encoding:'UTF-8',standalone:null}
  });

  return builder.buildObject(xml);
}

/**
 * writeDebugXmlIfEnabled(mutatedDocumentXmlString,debugPath)
 *
 * Caller is responsible for checking the --debug-xml flag before calling.
 */
function writeDebugXmlIfEnabled(mutatedDocumentXmlString,debugPath) {
  fs.writeFileSync(debugPath,mutatedDocumentXmlString,'utf8');
}

async function buildTempDocxWithMutatedDocumentXml(docxPath,{debugXml}) {
  const original=fs.readFileSync(docxPath);
  const zip=await JSZip.loadAsync(original);

  const docEntry=zip.file('word/document.xml');
  if (!docEntry) {
    throw new Error('Could not find word/document.xml inside docx.');
  }

  const documentXmlString=await docEntry.async('string');
  const mutatedXmlString=await injectFieldCodeSentinels(documentXmlString);

  if (debugXml) {
    const debugPath=`${docxPath}.debug.xml`;
    writeDebugXmlIfEnabled(mutatedXmlString,debugPath);
  }

  zip.file('word/document.xml',mutatedXmlString);

  const tmpDir=os.tmpdir();
  const tmpName=`snippet-mirror-${crypto.randomUUID()}.docx`;
  const tmpPath=path.join(tmpDir,tmpName);

  const outBuffer=await zip.generateAsync({type:'nodebuffer',compression:'DEFLATE'});
  fs.writeFileSync(tmpPath,outBuffer);

  return tmpPath;
}

function runPandoc({inputDocxPath,format}) {
  // Pandoc “to” targets:
  // - gfm for GitHub-flavored markdown
  // - html for HTML
  const to=isHtmlFormat(format) ? 'html' : 'gfm';

  const result=spawnSync('pandoc',['-f','docx','-t',to,inputDocxPath],{
    encoding:'utf8',
    stdio:['ignore','pipe','pipe']
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`pandoc failed (exit ${result.status}):\n${result.stderr || ''}`);
  }
  return result.stdout || '';
}

/**
 * mergeAdjacentCodeSpans(markdown)
 *
 * After replacing sentinels with backticks, pandoc output can produce sequences like:
 *   `DOCPROPERTY Foo` `DOCPROPERTY Bar`
 * or:
 *   `A`   `B`
 *
 * This merges adjacent code spans that are immediately adjacent or separated only by whitespace:
 *   `A` `B`  =>  `A B`
 */
function mergeAdjacentCodeSpans(markdown) {
  const codeSpan=/`([^`]+)`/g;

  // Step 1: tokenize into an array of {type:'code'|'text',value}
  const tokens=[];
  let lastIndex=0;
  for (;;) {
    const match=codeSpan.exec(markdown);
    if (!match) break;
    const [fullMatch,codeText]=match;
    const start=match.index;
    const end=start+fullMatch.length;

    if (start > lastIndex) {
      tokens.push({type:'text',value:markdown.slice(lastIndex,start)});
    }
    tokens.push({type:'code',value:codeText});
    lastIndex=end;
  }
  if (lastIndex < markdown.length) {
    tokens.push({type:'text',value:markdown.slice(lastIndex)});
  }

  // Step 2: merge code spans separated only by whitespace text tokens
  const merged=[];
  for (let i=0;i<tokens.length;i++) {
    const current=tokens[i];
    if (current.type !== 'code') {
      merged.push(current);
      continue;
    }

    let combined=current.value.trim();
    let j=i+1;

    while (j+1 < tokens.length && tokens[j].type === 'text' && /^\s*$/.test(tokens[j].value) && tokens[j+1].type === 'code') {
      combined=`${combined} ${tokens[j+1].value.trim()}`.trim();
      j+=2;
    }

    merged.push({type:'code',value:combined});
    i=j-1;
  }

  // Step 3: rebuild
  return merged.map(t=>{
    if (t.type === 'code') return `\`${t.value}\``;
    return t.value;
  }).join('');
}

/**
 * mergeAdjacentHtmlCurlyBlocks(html)
 *
 * After replacing sentinels with {{ }} tokens, output may contain:
 *   {{A}} {{B}}
 * or:
 *   {{A}}\n  {{B}}
 *
 * Merge into:
 *   {{A B}}
 */
function mergeAdjacentHtmlCurlyBlocks(html) {
  // Tokenize on {{...}} sequences (non-greedy).
  const block=/\{\{([\s\S]*?)\}\}/g;

  const tokens=[];
  let lastIndex=0;
  for (;;) {
    const match=block.exec(html);
    if (!match) break;
    const [fullMatch,inner]=match;
    const start=match.index;
    const end=start+fullMatch.length;

    if (start > lastIndex) {
      tokens.push({type:'text',value:html.slice(lastIndex,start)});
    }
    tokens.push({type:'curly',value:inner});
    lastIndex=end;
  }
  if (lastIndex < html.length) {
    tokens.push({type:'text',value:html.slice(lastIndex)});
  }

  const merged=[];
  for (let i=0;i<tokens.length;i++) {
    const current=tokens[i];
    if (current.type !== 'curly') {
      merged.push(current);
      continue;
    }

    let combined=current.value.trim();
    let j=i+1;

    while (j+1 < tokens.length && tokens[j].type === 'text' && /^\s*$/.test(tokens[j].value) && tokens[j+1].type === 'curly') {
      combined=`${combined} ${tokens[j+1].value.trim()}`.trim();
      j+=2;
    }

    merged.push({type:'curly',value:combined});
    i=j-1;
  }

  return merged.map(t=>{
    if (t.type === 'curly') return `{{${t.value}}}`;
    return t.value;
  }).join('');
}

function postProcessPandocOutput(raw,{format}) {
  if (isHtmlFormat(format)) {
    const replaced=raw
      .split(SENTINEL_PRE).join('{{')
      .split(SENTINEL_POST).join('}}');
    return mergeAdjacentHtmlCurlyBlocks(replaced);
  }

  // Markdown / gfm:
  const replaced=raw
    .split(SENTINEL_PRE).join('`')
    .split(SENTINEL_POST).join('`');

  return mergeAdjacentCodeSpans(replaced);
}

function removeFileIfExists(filePath) {
  try {
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
  } catch {}
}

export async function generateSnippetMirror({docxPath,format,debugXml}) {
  const normalizedFormat=normalizeFormat(format);
  const mirrorPath=mirrorPathForDocx(docxPath,normalizedFormat);

  ensureDirForFile(mirrorPath);

  const tempDocxPath=await buildTempDocxWithMutatedDocumentXml(docxPath,{debugXml});

  try {
    const rawPandoc=runPandoc({inputDocxPath:tempDocxPath,format:normalizedFormat});
    const cleaned=postProcessPandocOutput(rawPandoc,{format:normalizedFormat});
    fs.writeFileSync(mirrorPath,cleaned,'utf8');
  } finally {
    removeFileIfExists(tempDocxPath);
  }

  return {mirrorPath};
}

async function main() {
  const args=parseCliArgs(process.argv);

  if (!args.docxPath) {
    console.error('Usage: node scripts/generate-snippet-mirror.js <snippets/.../*.docx> [format=gfm|html] [--debug-xml]');
    process.exit(2);
  }

  assertFileExists(args.docxPath,'DOCX file');

  const {mirrorPath}=await generateSnippetMirror({
    docxPath:args.docxPath,
    format:args.format,
    debugXml:args.debugXml
  });

  console.log(`Wrote mirror: ${mirrorPath}`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(err=>{
    console.error(err?.stack || String(err));
    process.exit(1);
  });
}
