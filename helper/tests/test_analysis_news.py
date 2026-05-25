"""新增功能纯逻辑测试：新闻情绪/相关度/去重 + 单股分析的映射函数。
不依赖网络（_em_search 用 mock）；analyze_one 仅测纯函数（不触发 akshare）。
"""
from unittest.mock import patch

import pandas as pd


# ============================ fetch._news_sentiment ============================

class TestNewsSentiment:
    def test_bull(self):
        from fetch import _news_sentiment
        assert _news_sentiment("公司中标重大订单 签约") == "bull"

    def test_bear(self):
        from fetch import _news_sentiment
        assert _news_sentiment("公司亏损 遭立案调查") == "bear"

    def test_neutral_empty(self):
        from fetch import _news_sentiment
        assert _news_sentiment("公司召开股东大会") == "neutral"

    def test_tie_is_neutral(self):
        from fetch import _news_sentiment
        # 中标(+1) vs 亏损(-1) 持平 → neutral
        assert _news_sentiment("中标 但 亏损") == "neutral"


# ============================ fetch.fetch_news ============================

class TestFetchNews:
    FAKE = [
        {"title": "国货航：签订大订单", "url": "http://x/1?from=search", "content": "利好"},
        {"title": "国货航：公司一季度公告", "url": "http://x/1", "content": ""},  # 与上条同 URL（去参后）
        {"title": "某行业资金流向日报", "url": "http://x/2", "content": ""},        # 泛市场，relevance=0
        {"title": "001391 今日异动", "url": "http://x/3", "content": "亏损"},        # 含代码 relevance=1
    ]

    def test_relevance_dedup_sort_sentiment(self):
        import fetch
        with patch.object(fetch, "_em_search", return_value=self.FAKE):
            out = fetch.fetch_news("001391", "国货航")
        # 去重：http://x/1 去掉 query 后只剩一条
        keys = [i["url"].split("?", 1)[0] for i in out]
        assert keys.count("http://x/1") == 1
        # 相关度排序：标题含名称(2) 在最前，泛市场(0) 在最后
        assert out[0]["relevance"] == 2
        assert out[-1]["relevance"] == 0
        # 首条情绪 = bull（“签订/订单/利好”命中）
        assert out[0]["sentiment"] == "bull"
        # 含代码的条目 relevance=1、情绪=bear
        code_item = next(i for i in out if "x/3" in i["url"])
        assert code_item["relevance"] == 1
        assert code_item["sentiment"] == "bear"

    def test_empty_name_still_works(self):
        import fetch
        with patch.object(fetch, "_em_search", return_value=self.FAKE) as m:
            out = fetch.fetch_news("001391", "")
        assert m.called          # name 为空也能跑（回退用代码搜）
        assert len(out) >= 1


# ============================ analyze_one 纯映射函数 ============================

class TestAnalyzeMappings:
    def test_verdict_from_score(self):
        from analyze_one import _verdict_from_score
        assert _verdict_from_score(80) == "买入"
        assert _verdict_from_score(75) == "买入"
        assert _verdict_from_score(74) == "观望"
        assert _verdict_from_score(60) == "观望"
        assert _verdict_from_score(59) == "回避"

    def test_hold_action_map(self):
        from analyze_one import _HOLD_ACTION
        assert _HOLD_ACTION["止盈卖出"] == "止盈"
        assert _HOLD_ACTION["止损卖出"] == "止损"
        assert _HOLD_ACTION["清仓"] == "清仓"

    def test_index_direction(self):
        from analyze_one import _index_direction
        bull = pd.DataFrame({"close": [10, 11], "ma5": [9, 10.5], "ma10": [8, 10.0], "ma20": [7, 9.5]})
        bear = pd.DataFrame({"close": [10, 9], "ma5": [11, 9.5], "ma10": [12, 10.0], "ma20": [13, 10.5]})
        flat = pd.DataFrame({"close": [10, 10], "ma5": [10, 10.1], "ma10": [10, 9.9], "ma20": [10, 10.0]})
        assert _index_direction(bull) == 1
        assert _index_direction(bear) == -1
        assert _index_direction(flat) == 0
