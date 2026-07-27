whosthatbaseball/
├── src/main/java/com/delivery/
│   ├── Main.java              # 메인 진입점 (REQ15 텍스트 UI)
│   ├── db/
│   │   └── DBConnection.java  # DB 연결 관리
│   └── menu/
│       ├── InsertMenu.java    # INSERT 메뉴 2개 (REQ5)
│       ├── SelectMenu.java    # SELECT 메뉴 5개 (REQ6, REQ7)
│       ├── UpdateMenu.java    # UPDATE 메뉴 2개 (REQ8, REQ12, REQ13)
│       └── DeleteMenu.java    # DELETE 메뉴 2개 (REQ9)
├── sql/
│   ├── kbo_player_schema.sql      # 플레이어 스키마 생성 (REQ16)
│   ├── initdata.sql           # 초기 데이터 삽입 (REQ16)
│   └── dropschema.sql         # 전체 삭제 (REQ16)
├── data/
│   ├── player.json            # 플레이어 스키마 생성 (REQ16)
│   ├── initdata.sql           # 초기 데이터 삽입 (REQ16)
│   └── 
├── index.html
├── style.css
└── README.md
