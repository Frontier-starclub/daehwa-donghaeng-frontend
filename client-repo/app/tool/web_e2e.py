"""Rendered Chromium smoke test against a running app and fixture API stack."""

import argparse
import base64
import re
from pathlib import Path

from playwright.sync_api import expect, sync_playwright

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--url", default="http://127.0.0.1:3000")
parser.add_argument("--artifacts", type=Path, default=Path("/tmp/daehwa-web-e2e"))
args = parser.parse_args()
args.artifacts.mkdir(parents=True, exist_ok=True)
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, args=["--no-sandbox"])
    page = browser.new_page(viewport={"width": 420, "height": 900})

    def click_button(label):
        locator = page.get_by_role("button", name=label, exact=True)
        for _ in range(20):
            if locator.count():
                locator.click()
                return
            page.mouse.move(210, 700)
            page.mouse.wheel(0, 500)
            page.wait_for_timeout(150)
        raise AssertionError("Button not reachable: " + label)

    failures = []
    page.on("pageerror", lambda error: failures.append(str(error)))
    page.goto(args.url)
    page.locator("flt-semantics-placeholder").wait_for(state="attached")
    page.locator("flt-semantics-placeholder").dispatch_event("click")
    page.get_by_role("textbox").fill("화면 E2E 테스트")
    page.get_by_role("button", name="시작하기", exact=True).click()
    expect(page.get_by_text("처음 이용 설정", exact=True)).to_be_visible()
    page.get_by_role("button", name="이 설정으로 시작하기", exact=True).click()
    expect(page.get_by_role("button", name="약 등록하기", exact=True)).to_be_visible()
    page.get_by_role("button", name="약 등록하기", exact=True).click()
    page.get_by_role("button", name="사진 찍기", exact=True).click()
    with page.expect_file_chooser() as chooser:
        page.get_by_role("button", name="앨범에서 선택", exact=True).click()
    chooser.value.set_files(
        {
            "name": "fixture.png",
            "mimeType": "image/png",
            "buffer": base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
            ),
        }
    )
    page.get_by_role("button", name="이 사진 사용", exact=True).click()
    expect(page.get_by_text("이 약이 맞나요?", exact=True)).to_be_visible()
    page.get_by_role("button", name="이 내용으로 등록", exact=True).click()
    expect(page.get_by_text("약 등록 완료", exact=True)).to_be_visible()
    expect(page.get_by_text("E2E 가상 병용금기 응답", exact=False)).to_be_attached()
    page.get_by_role("button", name="복약 시간 설정", exact=True).first.click()
    page.get_by_role("button", name="시간 추가하기", exact=True).click()
    page.get_by_role("button", name="선택", exact=True).click()
    page.get_by_role("button", name="이 시간으로 저장", exact=True).click()
    click_button("홈으로")
    click_button("드셨어요")
    expect(page.locator("body")).to_contain_text("드셨어요")
    page.reload()
    page.locator("flt-semantics-placeholder").wait_for(state="attached")
    page.locator("flt-semantics-placeholder").dispatch_event("click")
    expect(page.locator("body")).to_contain_text("드셨어요")
    click_button("설정")
    page.get_by_role("switch", name=re.compile("^내 대화 변화 살펴보기")).click()
    page.get_by_role("switch", name=re.compile("^보호자에게 기록 공유")).click()
    page.get_by_role("switch", name=re.compile("^복약 기록 공유")).click()
    click_button("설정 저장")
    expect(page.locator("body")).to_contain_text("설정을 저장했어요.")
    click_button("뒤로")
    click_button("이야기 나누기")
    click_button("네, 좋아요")
    expect(
        page.get_by_role("group", name=re.compile("대화동행 안녕하세요"))
    ).to_be_visible()
    click_button("읽어주기 중지")
    expect(page.get_by_role("textbox")).to_be_enabled()
    page.get_by_role("textbox").press_sequentially("오늘 산책했어요", delay=30)
    click_button("이 내용 보내기")
    expect(
        page.get_by_role("group", name=re.compile("대화동행 반가워요"))
    ).to_be_attached()
    click_button("읽어주기 중지")
    expect(page.get_by_role("textbox")).to_be_enabled()
    page.get_by_role("textbox").press_sequentially(
        "이전 이야기를 기억하세요?", delay=30
    )
    expect(page.get_by_role("textbox")).to_have_value("이전 이야기를 기억하세요?")
    click_button("이 내용 보내기")
    expect(
        page.get_by_role("group", name=re.compile("대화동행 앞서 산책"))
    ).to_be_attached()
    click_button("읽어주기 중지")
    page.screenshot(path=str(args.artifacts / "conversation.png"))
    click_button("대화 마치기")
    click_button("홈으로")
    click_button("내 변화 요약")
    expect(page.locator("body")).to_contain_text("최근 대화 1회")
    page.screenshot(path=str(args.artifacts / "insights.png"))
    click_button("뒤로")
    click_button("보호자 연결과 리포트")
    click_button("보호자 초대 코드 만들기")
    expect(page.get_by_role("button", name="코드 복사", exact=True)).to_be_attached()
    click_button("내가 공유하는 리포트 미리보기")
    expect(page.locator("body")).to_contain_text("복용 확인 1회")
    expect(page.locator("body")).not_to_contain_text("오늘 산책했어요")
    page.screenshot(path=str(args.artifacts / "caregiver-report.png"))
    assert not failures, failures
    print(
        "PASS: registration → OCR → DUR → schedule → taken → reload → consent → contextual chat → analysis → caregiver preview"
    )
    browser.close()
