import torch


class ThorDFlashInt8Head:
    def __init__(self, weight, num_org=248320, tp_size=1, org_vocab_start=0):
        if torch.cuda.is_current_stream_capturing():
            raise RuntimeError('Initialize Thor draft INT8 head before graph capture')
        if (
            tuple(weight.shape) != (248320, 5120)
            or weight.dtype != torch.bfloat16
            or not weight.is_cuda
            or tp_size != 1
            or num_org != 248320
            or org_vocab_start != 0
        ):
            raise RuntimeError('Thor draft INT8 head requires full BF16 248320x5120 head on CUDA, TP=1')
        self.weight = weight
        self.source_ptr = weight.data_ptr()
        self.qweight = torch.empty_like(weight, dtype=torch.int8)
        self.scales = torch.empty((weight.shape[0], 1), dtype=torch.float32, device=weight.device)
        for begin in range(0, weight.shape[0], 4096):
            values = weight[begin:begin + 4096].float()
            scale = values.abs().amax(1, keepdim=True).clamp_min(1e-12) / 127
            self.scales[begin:begin + 4096] = scale
            self.qweight[begin:begin + 4096] = (values / scale).round().clamp(-127, 127).to(torch.int8)
        print('THOR_DFLASH_INT8 ready: full vocabulary, separate draft weights; target BF16 preserved', flush=True)

    def __call__(self, hidden_states):
        if (
            hidden_states.dtype != torch.bfloat16
            or hidden_states.device != self.weight.device
            or hidden_states.shape[-1] != 5120
            or self.weight.dtype != torch.bfloat16
            or self.weight.data_ptr() != self.source_ptr
        ):
            raise RuntimeError('Thor draft INT8 head source or hidden-state contract changed')
        x = hidden_states.reshape(-1, 5120).float()
        if x.shape[0] == 0:
            return hidden_states.new_empty((*hidden_states.shape[:-1], 248320))
        scales = x.abs().amax(1, keepdim=True).clamp_min(1e-12) / 127
        qx = (x / scales).round().clamp(-127, 127).to(torch.int8)
        pad = (32 - qx.shape[0] % 32) % 32
        if pad:
            qx = torch.nn.functional.pad(qx, (0, 0, 0, pad))
        logits = torch._int_mm(qx, self.qweight.T)[:x.shape[0]]
        logits = (logits.float() * scales * self.scales.T).to(torch.bfloat16)
        return logits.reshape(*hidden_states.shape[:-1], -1)


class ThorDraftHiddenCapture:
    def __init__(self, directory, limit=32):
        from pathlib import Path
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.limit = max(1, min(int(limit), 32))
        self.count = 0
        self.case_counts = {}

    def capture(self, hidden, tokens, quantized, folded, candidate_ids=None, candidate_logits=None):
        if self.count >= self.limit:
            return
        try:
            case = (self.directory / 'enabled').read_text().strip() or 'unknown'
        except FileNotFoundError:
            return
        if self.case_counts.get(case, 0) >= 16:
            return
        if tuple(hidden.shape) != (7, 5120) or tokens.numel() != 7:
            raise RuntimeError('Thor hidden capture requires BS=1, block=8, hidden=5120')
        record = {
            'case': case,
            'hidden': hidden.detach().to('cpu'),
            'draft_tokens': tokens.detach().reshape(-1).to('cpu'),
            'draft_int8': bool(quantized),
            'folded': bool(folded),
        }
        if candidate_ids is not None:
            if candidate_logits is None or candidate_ids.shape != candidate_logits.shape or candidate_ids.shape[0] != 7:
                raise RuntimeError('Invalid pre-selector candidate buffers')
            record['candidate_ids'] = candidate_ids.detach().to('cpu')
            record['candidate_logits'] = candidate_logits.detach().to('cpu')
        path = self.directory / f'hidden-{self.count:03d}.pt'
        if path.exists():
            raise RuntimeError(f'Refusing to overwrite existing hidden sample: {path}')
        torch.save(record, path)
        self.count += 1
        self.case_counts[case] = self.case_counts.get(case, 0) + 1
        print(f'THOR_DFLASH_HIDDEN sample={path} case={case} int8={quantized} folded={folded}', flush=True)
