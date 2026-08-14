from __future__ import annotations

from dataclasses import asdict, dataclass
from hashlib import sha256
import re
from typing import Any


PROTOCOL_VERSION = 5
MAX_CHAPTER_CHARACTERS = 100_000
SENTENCE_ENDINGS = frozenset("。！？!?；;\n")
SOFT_ENDINGS = frozenset("，,、：:")
MULTI_ROLE_VOICE = "multi-role"
ROLE_NARRATOR = "narrator"
ROLE_PROTAGONIST = "protagonist"
ROLE_MALE = "male"
ROLE_FEMALE = "female"
SPEECH_VERBS = (
    "低声说道|轻声说道|大声说道|低声问|轻声问|大声问|"
    "低声说|轻声说|大声说|笑着说|哭着说|笑道|哭道|"
    "回应|回答|开口|说道|说|问|喊|叫|答|道"
)
SPEAKER_ACTIONS = (
    "郑重其事地", "一字一顿地", "斩钉截铁地", "不可置信地", "歇斯底里地",
    "疑惑地", "耐心地", "关切地", "惊恐地", "激动地", "严肃地", "认真地",
    "轻声", "低声", "大声", "沉声", "笑着", "哭着", "叹着气", "回过头",
    "立即", "马上", "随即", "忽然", "突然", "连忙", "缓缓", "首先", "继续",
    "不禁", "索性", "终于", "开始", "发现", "感觉", "认为", "回忆", "解释",
    "提议", "补充", "反问", "追问", "回敬", "安慰", "劝解", "咆哮", "喃喃",
    "看", "望", "听", "想", "笑", "哭", "叹", "走", "跑", "站", "坐", "转",
    "拿", "放", "把", "将", "向", "对", "给", "递", "拍", "拉", "推", "冲",
    "点", "摇", "托", "抬", "问", "说", "答", "喊", "叫", "吼", "道", "开口",
    "回应", "回答", "点了点头", "点点头", "叹了口气", "说到这里", "看起来",
    "站起身", "蹲下身", "回过头", "接过", "拿起", "捡起", "抓住", "揪住",
    "喝止", "知道", "知", "分析", "决定", "一惊", "会心", "悄悄", "冷冷", "冷",
    "默默", "耐心", "急忙", "扶起", "纠正", "纠", "苦笑", "苦", "猛然", "猛",
    "重重", "狠狠", "先是", "则是", "实在", "尽力", "不希望", "很少",
    "一听", "一看", "一说", "一想", "一愣", "一笑", "边哭边",
    "那么", "大概", "慢慢", "又", "还", "也", "就", "才", "正", "却", "便",
)
SPEAKER_LEADING_FILLERS = (
    "过了一会儿", "临走以前", "与此同时", "这个时候", "那时候", "这时候", "不久后",
    "片刻后", "接下来", "随后", "接着", "然后", "于是", "同时", "此时", "这时", "此刻",
    "紧接着", "一时间", "一时", "后脚", "当时", "刚刚", "刚要", "立刻", "即刻",
    "好不容易", "好半天", "半天", "表面上", "回想起", "越来越", "一边",
    "直接", "迅速", "无奈", "仔细", "猛然", "连连", "抢先", "再",
    "可是", "但是", "不过", "原来", "谁知", "见状", "闻言", "最终", "顿时",
    "虽然说", "虽然", "因为", "由于", "所以", "然而", "反而", "其实", "居然",
    "甚至", "而且", "只好", "而", "但", "可", "让", "一个", "一名", "一位",
    "那名", "那位", "这名", "这位", "这个", "那个",
    "年轻", "年迈",
)
GENERIC_FEMALE_SPEAKERS = frozenset(("女孩", "女人", "女子", "姑娘", "小姐", "女士", "母亲", "妻子", "姐姐", "妹妹", "少女", "女生", "女学生", "空姐", "女管家", "女警", "护士"))
GENERIC_MALE_SPEAKERS = frozenset(("男孩", "男人", "男子", "少年", "先生", "男士", "父亲", "丈夫", "哥哥", "弟弟", "老者", "男生", "皇帝", "太医"))
GENERIC_ROLE_SPEAKERS = frozenset(
    (
        "老人", "夫人", "医生", "护士", "警察", "民警", "老师", "校长", "副校长",
        "记者", "管家", "董事长", "太子", "太医", "侍卫", "司机", "店员", "服务员",
    )
)
COMMON_SURNAMES = frozenset(
    "赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜"
    "戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳鲍史唐"
    "费廉岑薛雷贺倪汤滕殷罗毕郝安常乐于时傅皮卞齐康伍余元卜顾孟平黄"
    "和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴宋茅庞熊纪舒屈项祝董梁"
    "杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林钟徐邱骆高夏蔡田樊胡凌霍"
    "虞万支柯管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚"
    "程嵇邢滑裴陆荣翁荀羊甄曲封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗"
    "山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘厉戎祖武符刘景詹束龙叶幸"
    "司韶郜黎蓟薄印宿白怀蒲邰鄂索咸籍赖卓蔺屠蒙池乔阴郁胥能苍双闻莘"
    "党翟谭贡劳逄姬申扶堵冉宰郦雍却璩桑桂濮牛寿通边扈燕冀浦尚农温别"
    "庄晏柴瞿阎慕连茹习宦艾容向古易慎戈廖庾终暨居衡步都耿满弘匡国文"
    "寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋"
    "沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公"
)
SPEAKER_STOPWORDS = frozenset(
    (
        "眼睛", "眼神", "照片", "表格", "答案", "小事", "身影", "身后", "其中",
        "旁边", "楼上", "电梯", "磁带", "房间", "声音", "语气", "表情", "目光",
        "一拳", "一点", "那里", "这里", "众人", "大家", "没有人", "另外一人",
        "高大身影", "恐怖小", "不是小事", "关上门", "门被打开", "起照片",
        "手上", "脑子", "双手紧", "双拳紧攥", "房子有鬼", "话是", "嘴上是",
        "话虽然是", "话锋一", "一把", "牌", "精神", "收费", "无人", "有些",
        "越来越大", "另一只手", "详细", "是有", "上前", "下车", "徐徐",
        "摄影师", "经理", "朋友", "自行车", "疑惑", "扯开嗓子", "了一番后",
        "没有任何", "的答案", "详细解释", "三人", "女的", "意思是", "很难接受",
        "起了什么", "谁也不", "后者也", "住他", "坦白", "另外", "赞叹", "反复",
        "倒还", "鞠躬", "壮着胆子", "睛", "字", "狞", "锁", "询", "喝", "微",
        "是打算", "之后", "直到",
    )
)
INVALID_SPEAKER_NAMES = frozenset(
    (
        "说道", "说", "问道", "问", "回答", "回答道", "回应", "开口", "喊", "叫", "答", "道", "吼",
        "耐心地", "疑惑地", "轻声", "低声", "大声", "沉声", "笑着", "哭着", "叹着气",
        "甚至还", "接着", "然后", "于是", "随即", "谁知", "这个", "那个", "名字", "声音",
        "口吻", "语气", "表情", "点头", "摇头", "回过头", "一个同事", "一个人",
        "连忙", "立即", "忽然", "突然", "继续", "叹了口气", "点了点头", "点点头",
        "说到这里", "点头回答", "阿静此刻", "前者", "后者",
    )
)


class ProtocolError(ValueError):
    pass


def require_string(payload: dict[str, Any], key: str, maximum: int) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise ProtocolError(f"字段 {key} 必须是字符串")
    value = value.strip()
    if not value:
        raise ProtocolError(f"字段 {key} 不能为空")
    if len(value) > maximum:
        raise ProtocolError(f"字段 {key} 超过长度限制")
    return value


def normalize_narration_text(text: str) -> str:
    lines = [line.strip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    return "\n".join(line for line in lines if line)


def split_narration_text(text: str, maximum: int = 240, minimum: int = 45) -> list[str]:
    if maximum < 20 or minimum < 1 or minimum >= maximum:
        raise ValueError("分段长度设置无效")
    if not text:
        return []

    chunks: list[str] = []
    start = 0
    last_soft_break: int | None = None
    for index, character in enumerate(text):
        length = index - start + 1
        if character in SOFT_ENDINGS:
            last_soft_break = index + 1
        if character in SENTENCE_ENDINGS and length >= minimum:
            chunks.append(text[start : index + 1])
            start = index + 1
            last_soft_break = None
            continue
        if length >= maximum:
            end = last_soft_break if last_soft_break and last_soft_break > start else index + 1
            chunks.append(text[start:end])
            start = end
            last_soft_break = None

    if start < len(text):
        chunks.append(text[start:])
    return [chunk for chunk in chunks if chunk]


@dataclass(frozen=True)
class NarrationChunk:
    text: str
    start_offset: int
    end_offset: int
    role: str = ROLE_NARRATOR
    speaker: str | None = None
    gender: str | None = None


def split_narration_chunks(
    text: str,
    voice: str,
    maximum: int = 240,
    minimum: int = 45,
) -> list[NarrationChunk]:
    dialogue_ranges = _dialogue_ranges(text)
    source_spans = _source_spans(text, dialogue_ranges) if voice == MULTI_ROLE_VOICE else [(0, len(text), False)]
    raw_chunks: list[tuple[str, int, int, bool]] = []
    for span_start, span_end, is_dialogue in source_spans:
        span_text = text[span_start:span_end]
        local_offset = 0
        span_chunks = (
            [span_text]
            if is_dialogue and len(span_text) <= maximum
            else split_narration_text(span_text, maximum=maximum, minimum=minimum)
        )
        for value in span_chunks:
            start = span_start + local_offset
            end = start + len(value)
            raw_chunks.append((value, start, end, is_dialogue))
            local_offset += len(value)
    if not raw_chunks:
        return []

    protagonist: str | None = None
    known_roles: dict[str, str] = {}
    recent_speakers: dict[str, str] = {}
    unknown_dialogue_count = 0
    previous_dialogue: tuple[str | None, str | None, str] | None = None
    result: list[NarrationChunk] = []
    for chunk, start, end, is_dialogue in raw_chunks:
        role = ROLE_NARRATOR
        speaker: str | None = None
        gender: str | None = None
        if voice == MULTI_ROLE_VOICE and is_dialogue:
            context_start = max(0, start - 40)
            context_end = min(len(text), end + 40)
            context = text[context_start:context_end]
            speaker = _speaker_name(context, start - context_start, text)
            gender = _speaker_gender(speaker, context, text)
            if speaker is None and previous_dialogue is not None:
                speaker, gender, role = previous_dialogue
            if speaker in {"她", "他"}:
                antecedent = _pronoun_antecedent(context, start - context_start, speaker)
                speaker = (
                    antecedent
                    if is_valid_speaker_name(antecedent)
                    else recent_speakers.get(gender or "") or speaker
                )

            if speaker and speaker not in {"他", "她", "它", "我", "你", "您"}:
                if gender:
                    recent_speakers[gender] = speaker
                if protagonist is None:
                    protagonist = speaker
                    known_roles[speaker] = ROLE_PROTAGONIST
                role = known_roles.get(speaker, gender or ROLE_MALE)
                known_roles.setdefault(speaker, role)
            elif protagonist is None:
                protagonist = speaker or "__first_dialogue__"
                role = ROLE_PROTAGONIST
            elif gender:
                role = gender
            else:
                role = ROLE_MALE if unknown_dialogue_count % 2 == 0 else ROLE_FEMALE
                unknown_dialogue_count += 1
            previous_dialogue = (speaker, gender, role)
        else:
            previous_dialogue = None

        result.append(
            NarrationChunk(
                chunk,
                start,
                end,
                role,
                speaker,
                gender,
            )
        )

    return result


def timing_ranges(text: str, maximum: int = 52, minimum: int = 10) -> list[tuple[int, int]]:
    chunks = split_narration_text(text, maximum=maximum, minimum=minimum)
    result: list[tuple[int, int]] = []
    offset = 0
    for chunk in chunks:
        end = offset + len(chunk)
        result.append((offset, end))
        offset = end
    return result


def _dialogue_ranges(text: str) -> list[tuple[int, int]]:
    pairs = {"“": "”", "‘": "’", '"': '"'}
    ranges: list[tuple[int, int]] = []
    opening: str | None = None
    start = 0
    for index, character in enumerate(text):
        if opening is None and character in pairs:
            opening = character
            start = index
        elif opening is not None and character == pairs[opening]:
            ranges.append((start, index + 1))
            opening = None
    if opening is not None:
        ranges.append((start, len(text)))
    return ranges


def _overlaps_dialogue(start: int, end: int, ranges: list[tuple[int, int]]) -> bool:
    return any(max(start, left) < min(end, right) for left, right in ranges)


def _source_spans(text: str, dialogue_ranges: list[tuple[int, int]]) -> list[tuple[int, int, bool]]:
    result: list[tuple[int, int, bool]] = []
    cursor = 0
    for start, end in dialogue_ranges:
        if cursor < start:
            result.append((cursor, start, False))
        result.append((start, end, True))
        cursor = end
    if cursor < len(text):
        result.append((cursor, len(text), False))
    return result


def _speaker_name(context: str, anchor: int, full_text: str) -> str | None:
    before = context[: anchor + 1]
    attribution = re.search(
        rf"(?:{SPEECH_VERBS})[，,:：\s]*[“‘\"]$",
        before,
    )
    if attribution:
        speaker = _speaker_subject(before[: attribution.start()], full_text)
        if speaker:
            return speaker

    after = context[anchor:]
    attribution = re.search(
        rf"[”’\"][，,。！？!?\s]*(?P<clause>[^“”‘’\"。！？!?\n]{{0,48}}?)"
        rf"(?:{SPEECH_VERBS})(?=[，,。！？!?：:\s]|$)",
        after,
    )
    if attribution:
        speaker = _speaker_subject(attribution.group("clause"), full_text)
        if speaker:
            return speaker
    return None


def _speaker_subject(value: str, full_text: str) -> str | None:
    sentence = re.split(r"[。！？!?；;\n“”‘’\"]", value)[-1]
    candidates: list[str] = []
    for raw_segment in re.split(r"[，,：:]", sentence):
        segment = raw_segment.strip()
        changed = True
        while segment and changed:
            changed = False
            for filler in SPEAKER_LEADING_FILLERS + SPEAKER_ACTIONS:
                if segment.startswith(filler):
                    segment = segment[len(filler) :].lstrip()
                    changed = True
                    break
        if not segment:
            continue
        if segment[0] in {"她", "他", "我", "你", "您"}:
            candidates.append(segment[0])
            continue
        generic = next(
            (
                label
                for label in GENERIC_FEMALE_SPEAKERS | GENERIC_MALE_SPEAKERS | GENERIC_ROLE_SPEAKERS
                if segment.startswith(label)
            ),
            None,
        )
        if generic:
            candidates.append(generic)
            continue
        found_prefixed_subject = False
        for length in range(2, min(4, len(segment)) + 1):
            candidate = segment[:length]
            remainder = segment[length:]
            if any(
                remainder.startswith(action)
                for action in SPEAKER_ACTIONS + SPEAKER_LEADING_FILLERS
            ) and is_valid_speaker_name(candidate):
                candidates.append(candidate)
                found_prefixed_subject = True
                break
        if found_prefixed_subject:
            continue
        if 1 <= len(segment) <= 4 and is_valid_speaker_name(segment):
            candidates.append(segment)
    return candidates[-1] if candidates else None


def _clean_speaker_name(value: str) -> str:
    cleaned = re.sub(
        r"(?:忽然|突然|连忙|缓缓|轻轻|低声|轻声|大声|沉声|笑着|哭着)+$",
        "",
        value,
    )
    return cleaned[-4:]


def is_valid_speaker_name(value: str | None, evidence_text: str | None = None) -> bool:
    if not value:
        return False
    if value in {"她", "他", "我", "你", "您"}:
        return True
    if value in INVALID_SPEAKER_NAMES:
        return False
    if value in SPEAKER_STOPWORDS:
        return False
    if value in SPEAKER_ACTIONS or value in SPEAKER_LEADING_FILLERS:
        return False
    if value in GENERIC_FEMALE_SPEAKERS or value in GENERIC_MALE_SPEAKERS or value in GENERIC_ROLE_SPEAKERS:
        return True
    if not re.fullmatch(r"[\u4e00-\u9fff]{1,4}", value):
        return False
    if len(value) > 1 and value[0] in {"她", "他", "我", "你", "您", "其", "这", "那"}:
        return False
    if "的" in value:
        return False
    if value.startswith(("对", "向", "把", "将", "在", "从", "给", "听", "看着", "着", "并", "到", "了", "没有", "谁", "当", "住", "另外", "后者", "详细", "意思", "很难", "起了", "壮着", "扯开")):
        return False
    if value.endswith(("地", "着", "了", "过", "对", "向", "说", "问", "答", "喊", "叫", "道", "吼", "话", "声", "这里", "头", "口气", "身", "门", "去", "来", "里")):
        return False
    if len(value) >= 3 and value.endswith(("面", "心", "感", "一", "先", "倒", "蹲", "这么", "居然", "也", "是", "不", "刚", "解释", "什么", "接受")):
        return False
    if evidence_text is not None:
        if len(value) == 1:
            escaped = re.escape(value)
            gender_evidence = rf"{escaped}(?:她(?!们)|他(?!们))|(?:小姐|女士|先生|男士)[，、\s]*{escaped}"
            return re.search(gender_evidence, evidence_text) is not None
        occurrences = evidence_text.count(value)
        if value[0] in COMMON_SURNAMES or value.startswith(("阿", "小", "老")):
            return occurrences >= 2
        return occurrences >= 6
    return True


def _speaker_gender(speaker: str | None, context: str, full_text: str) -> str | None:
    female_markers = tuple(GENERIC_FEMALE_SPEAKERS)
    male_markers = tuple(GENERIC_MALE_SPEAKERS)
    if speaker == "她":
        return ROLE_FEMALE
    if speaker == "他":
        return ROLE_MALE
    if speaker in female_markers:
        return ROLE_FEMALE
    if speaker in male_markers:
        return ROLE_MALE
    if speaker and speaker not in {"它", "我", "你", "您"}:
        escaped = re.escape(speaker)
        female_pattern = (
            rf"(?:{'|'.join(female_markers)})[，、\s]*{escaped}|"
            rf"{escaped}(?:是|作为)?(?:一名|一位|个|位)?(?:年轻|年迈)?(?:{'|'.join(female_markers)})"
        )
        male_pattern = (
            rf"(?:{'|'.join(male_markers)})[，、\s]*{escaped}|"
            rf"{escaped}(?:是|作为)?(?:一名|一位|个|位)?(?:年轻|年迈)?(?:{'|'.join(male_markers)})"
        )
        if re.search(female_pattern, full_text):
            return ROLE_FEMALE
        if re.search(male_pattern, full_text):
            return ROLE_MALE
        speaker_position = context.find(speaker)
        if speaker_position >= 0:
            following = context[speaker_position + len(speaker) :]
            if re.search(r"[”’\"][^。！？!?]{0,40}这个(?:女人|女孩|姑娘|女士)", following):
                return ROLE_FEMALE
            if re.search(r"[”’\"][^。！？!?]{0,40}这个(?:男人|男孩|少年|男士)", following):
                return ROLE_MALE
    return None


def _pronoun_antecedent(context: str, anchor: int, pronoun: str) -> str | None:
    prefix = context[:anchor]
    if pronoun == "她":
        markers = "女孩|女人|姑娘|小姐|女士|母亲|妻子|姐姐|妹妹"
    else:
        markers = "男孩|男人|少年|先生|男士|父亲|丈夫|哥哥|弟弟"
    matches = list(
        re.finditer(
            rf"(?:年轻|年迈)?(?:{markers})([一-鿿]{{2,4}}?)(?="
            rf"站|坐|走|看|转|来|问|说|道|在|正|轻|低|大|，|。)",
            prefix,
        )
    )
    if not matches:
        return None
    candidate = matches[-1].group(1)
    return candidate if is_valid_speaker_name(candidate) else None


@dataclass(frozen=True)
class JobRequest:
    book_id: str
    book_title: str
    author: str
    chapter_id: str
    chapter_url: str
    chapter_index: int
    chapter_title: str
    text: str
    text_sha256: str
    voice: str
    speed: float

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "JobRequest":
        if payload.get("protocol_version") != PROTOCOL_VERSION:
            raise ProtocolError("客户端与生成器协议版本不一致")

        text = normalize_narration_text(require_string(payload, "text", MAX_CHAPTER_CHARACTERS))
        supplied_hash = require_string(payload, "text_sha256", 64).lower()
        actual_hash = sha256(text.encode("utf-8")).hexdigest()
        if supplied_hash != actual_hash:
            raise ProtocolError("正文校验失败，请重新提交本章")

        chapter_index = payload.get("chapter_index")
        if not isinstance(chapter_index, int) or chapter_index < 0:
            raise ProtocolError("章节序号无效")
        speed = payload.get("speed", 1.0)
        if not isinstance(speed, (int, float)) or not 0.5 <= float(speed) <= 2.0:
            raise ProtocolError("生成语速必须在 0.5 到 2.0 之间")

        return cls(
            book_id=require_string(payload, "book_id", 512),
            book_title=require_string(payload, "book_title", 256),
            author=str(payload.get("author", "")).strip()[:128],
            chapter_id=require_string(payload, "chapter_id", 128),
            chapter_url=require_string(payload, "chapter_url", 4096),
            chapter_index=chapter_index,
            chapter_title=require_string(payload, "chapter_title", 256),
            text=text,
            text_sha256=actual_hash,
            voice=str(payload.get("voice", "default")).strip()[:128] or "default",
            speed=float(speed),
        )

    @property
    def stable_job_id(self) -> str:
        fingerprint = "\n".join(
            ["timeline-v5-speaker-gender", self.book_id, self.chapter_id, self.text_sha256, self.voice, f"{self.speed:.2f}"]
        )
        return sha256(fingerprint.encode("utf-8")).hexdigest()[:32]

    def public_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value.pop("text")
        return value

    def storage_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_storage_dict(cls, payload: dict[str, Any]) -> "JobRequest":
        chapter_url = str(payload.get("chapter_url", "")).strip()
        chapter_id = str(payload.get("chapter_id", "")).strip()
        if not chapter_url:
            chapter_url = f"quietreader-legacy://chapter/{chapter_id}"
        return cls(
            book_id=str(payload["book_id"]),
            book_title=str(payload["book_title"]),
            author=str(payload.get("author", "")),
            chapter_id=chapter_id,
            chapter_url=chapter_url,
            chapter_index=int(payload["chapter_index"]),
            chapter_title=str(payload["chapter_title"]),
            text=str(payload.get("text", "")),
            text_sha256=str(payload["text_sha256"]),
            voice=str(payload.get("voice", "default")),
            speed=float(payload.get("speed", 1.0)),
        )
