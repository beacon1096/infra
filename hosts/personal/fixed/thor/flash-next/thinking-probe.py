"""Audit the local tokenizer's actual thinking template without loading the model."""

import argparse
import hashlib
import json
from pathlib import Path

from jinja2 import TemplateError
from transformers import AutoTokenizer


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--model-dir", type=Path, default=Path("/models/target"))
parser.add_argument("--fixtures", type=Path, required=True)
args = parser.parse_args()
tokenizer = AutoTokenizer.from_pretrained(str(args.model_dir), local_files_only=True)
template_file = args.model_dir / "chat_template.jinja"
template = tokenizer.chat_template
if not isinstance(template, str) or template != template_file.read_text():
    raise RuntimeError("tokenizer template does not match the recorded local Jinja file")
cases = json.loads(args.fixtures.read_text())["cases"]
reports = []
for case in cases:
    request = case["request"]
    kwargs = dict(request["chat_template_kwargs"])
    text = tokenizer.apply_chat_template(request["messages"], tokenize=False, add_generation_prompt=True, **kwargs)
    tokens = tokenizer.apply_chat_template(request["messages"], tokenize=True, return_dict=False,
                                           add_generation_prompt=True, **kwargs)
    if not isinstance(tokens, list) or any(type(token) is not int for token in tokens):
        raise RuntimeError("tokenizer did not return a flat integer token sequence")
    if len(tokens) > 2048 or request["max_tokens"] > 4096:
        raise RuntimeError("case exceeds this experiment's conservative input/output budget")
    enabled = kwargs["enable_thinking"]
    if enabled:
        if not text.endswith("<think>\n"):
            raise RuntimeError("thinking-on prompt does not open a reasoning block")
    elif not text.endswith("<think>\n\n</think>\n\n"):
        raise RuntimeError("thinking-off prompt does not close the reasoning block")
    reports.append({"id": case["id"], "thinking": enabled, "effort": kwargs.get("reasoning_effort"),
                    "prompt_tokens": len(tokens), "maximum_output_tokens": request["max_tokens"],
                    "rendered_prompt_sha256": hashlib.sha256(text.encode()).hexdigest(),
                    "token_ids_sha256": hashlib.sha256(json.dumps(tokens).encode()).hexdigest()})
messages = cases[0]["request"]["messages"]
rendered = {}
for effort in ("low", "medium", "xhigh"):
    rendered[effort] = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True,
                                                    enable_thinking=True, reasoning_effort=effort)
if len(set(rendered.values())) != 3:
    raise RuntimeError("reasoning effort settings render identical prompts")
default = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=True)
if default != rendered["xhigh"]:
    raise RuntimeError("default effort differs from the recorded xhigh behavior")
try:
    tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True,
                                  enable_thinking=True, reasoning_effort="high")
except TemplateError:
    unsupported_high = True
else:
    raise RuntimeError("high unexpectedly accepted; template assumptions changed")
print(json.dumps({"template_sha256": hashlib.sha256(template.encode()).hexdigest(),
                  "low_medium_xhigh_render_differently": True, "default_effort": "xhigh",
                  "unsupported_high_rejected": unsupported_high,
                  "scope": "local Jinja rendering; backend forwarding and generation require runtime checks",
                  "cases": reports}, indent=2), flush=True)
