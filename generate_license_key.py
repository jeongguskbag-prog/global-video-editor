"""
새 고객용 라이선스 키를 생성하는 간단한 스크립트.

사용법:
    python3 generate_license_key.py "고객 이름 또는 메모"

키를 하나 생성해서 화면에 출력해준다. 실제로 그 고객이 쓸 수 있게 하려면:
  1. Render 대시보드 -> global-video-editor 서비스 -> Environment 탭으로 이동
  2. LICENSES_JSON 환경변수를 연다 (처음이면 새로 추가, 값은 {} 로 시작)
  3. 출력된 한 줄을 기존 JSON 안에 합쳐 넣는다 (아래 "병합 예시" 참고)
  4. Save 하면 Render가 자동으로 재배포한다 (몇 분 소요)
  5. 재배포가 끝나면 그 키를 고객에게 전달한다

주의: LICENSES_JSON을 통째로 덮어쓰면 기존에 발급한 다른 고객 키가 사라진다.
반드시 기존 JSON에 "이어붙이는" 방식으로 수정할 것.
"""

import json
import secrets
import sys

ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 0/O, 1/I/L 같은 헷갈리는 문자 제외


def generate_key() -> str:
    groups = ["".join(secrets.choice(ALPHABET) for _ in range(4)) for _ in range(3)]
    return "GVE-" + "-".join(groups)


def main():
    owner = sys.argv[1] if len(sys.argv) > 1 else input("고객 이름 또는 메모: ").strip()
    key = generate_key()

    print()
    print(f"새 라이선스 키: {key}")
    print(f"소유자 메모:   {owner}")
    print()
    print("Render 환경변수 LICENSES_JSON에 아래 한 조각을 기존 JSON에 합쳐 넣으세요:")
    print(json.dumps({key: {"owner": owner}}, ensure_ascii=False, indent=2))
    print()
    print("예) 기존 값이 {\"GVE-AAAA-...\": {\"owner\": \"홍길동\"}} 였다면,")
    print("    합친 후 값은 {\"GVE-AAAA-...\": {\"owner\": \"홍길동\"}, \"" + key + "\": {\"owner\": \"" + owner + "\"}} 형태가 됩니다.")


if __name__ == "__main__":
    main()
