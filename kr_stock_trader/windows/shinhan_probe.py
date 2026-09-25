"""신한 indi TR 원시 응답 확인 도구 (Windows, 32비트 Python, 관리자 권한).

필드 순번이 indi 도움말과 맞는지 확인하는 용도다. 주문은 보내지 않는다.
    py -3-32 kr_stock_trader\\windows\\shinhan_probe.py 005930
출력의 각 칸 번호(0,1,2,...)를 보고 kr_stock_trader/brokers/shinhan.py 의 FIELDS 와 다르면
같은 구조의 JSON 파일을 만들어 SHINHAN_FIELDS_FILE 로 지정한다. 예:
    {"balance": {"out": {"qty": 3, "avg_price": 7}}, "cash": {"single": {"orderable": 4}}}
"""

import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))

from kr_stock_trader.brokers.shinhan import QtIndiSession, load_fields  # noqa: E402

N = 15  # 앞에서부터 출력할 칸 수


def main():
    code = sys.argv[1] if len(sys.argv) > 1 else "005930"
    fields = load_fields()
    s = QtIndiSession(os.environ.get("SHINHAN_ID", ""), os.environ.get("SHINHAN_PASSWORD", ""),
                      os.environ.get("SHINHAN_CERT_PASSWORD", ""),
                      os.environ.get("SHINHAN_STARTER", r"C:\SHINHAN-i\indi\GiExpertStarter.exe"))
    account, password = os.environ.get("SHINHAN_ACCOUNT", ""), os.environ.get("SHINHAN_ACCOUNT_PASSWORD", "")
    if not account or not password:
        sys.exit("SHINHAN_ACCOUNT / SHINHAN_ACCOUNT_PASSWORD 환경변수를 먼저 설정하세요")
    acc = {0: account.replace("-", ""), 1: "01", 2: password}
    chart = fields["chart"]
    ci = chart["in"]
    for title, tr, inputs in [
        ("차트(일봉 3개)", chart["tr"], {ci["code"]: code, ci["kind"]: "D", ci["interval"]: "1",
                                       ci["start"]: "00000000", ci["end"]: "99999999", ci["count"]: "3"}),
        ("잔고", fields["balance"]["tr"], acc),
        ("예수금", fields["cash"]["tr"], acc),
    ]:
        print(f"\n===== {title}: {tr}")
        try:
            res = s.request(tr, inputs, single=range(N), multi=range(N))
        except Exception as e:  # 진단 도구라 모든 오류를 보여 주고 계속한다
            print("  오류:", e)
            continue
        print("  single:", {k: v for k, v in res.single.items() if v})
        for n, row in enumerate(res.rows[:5]):
            print(f"  row{n}:", row)


if __name__ == "__main__":
    main()
