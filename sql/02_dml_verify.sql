-- ==========================================================
-- 데이터 변경 · 제약조건 · 트랜잭션 검증 (Supabase SQL Editor에서 실행)
-- 각 [번호] 블록을 "드래그로 선택 → Run"으로 하나씩 실행하고 결과를 캡처하세요.
-- ==========================================================

-- [1] INSERT: 전 → 후
SELECT count(*) AS products_before FROM public.products;

INSERT INTO public.products (id, seller_id, name, price, description)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001',
        (SELECT id FROM public.user_details WHERE role = 'seller' LIMIT 1),
        '검증용 만두', 9000, 'SQL 검증용');

SELECT id, name, price, stock_quantity FROM public.products
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- [2] UPDATE: 전 → 후 (modified_at 트리거 확인)
SELECT price, created_at, modified_at FROM public.products
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

UPDATE public.products SET price = 9500
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

SELECT price, created_at, modified_at FROM public.products
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';

-- [3] 제약조건 위반 (아래 6개를 "한 줄씩 따로" 실행하고, 빨간 에러 메시지를 캡처)
-- 3-1) 음수 가격 → CHECK 위반
INSERT INTO public.products (seller_id, name, price)
VALUES ((SELECT id FROM public.user_details WHERE role = 'seller' LIMIT 1), '음수가격', -1);

-- 3-2) 이름이 공백만 → CHECK 위반
INSERT INTO public.products (seller_id, name, price)
VALUES ((SELECT id FROM public.user_details WHERE role = 'seller' LIMIT 1), '   ', 1000);

-- 3-3) 존재하지 않는 판매자 → FK 위반
INSERT INTO public.products (seller_id, name, price)
VALUES (gen_random_uuid(), '없는판매자', 1000);

-- 3-4) 주문 수량 0 → CHECK 위반
INSERT INTO public.order_items (order_id, product_id, quantity, unit_price)
VALUES ((SELECT id FROM public.orders LIMIT 1), 'aaaaaaaa-0000-0000-0000-000000000001', 0, 100);

-- 3-5) 잘못된 role → CHECK 위반
UPDATE public.user_details SET role = 'superuser'
WHERE id = (SELECT id FROM public.user_details WHERE role = 'buyer' LIMIT 1);

-- 3-6) 주문 이력이 있는 상품 삭제 → ON DELETE RESTRICT로 FK 보호
DELETE FROM public.products WHERE name = '김치만두';

-- [4] 트랜잭션 ROLLBACK: 변경했다가 취소 → 값이 그대로여야 함
SELECT stock_quantity AS stock_before FROM public.products
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';          -- 100

BEGIN;
    UPDATE public.products SET stock_quantity = 0
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
ROLLBACK;

SELECT stock_quantity AS stock_after_rollback FROM public.products
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';          -- 여전히 100

-- [5] 트랜잭션 COMMIT: 변경이 확정됨
BEGIN;
    UPDATE public.products SET stock_quantity = stock_quantity - 1
    WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
COMMIT;

SELECT stock_quantity AS stock_after_commit FROM public.products
WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';          -- 99

-- [6] DELETE + 정리
DELETE FROM public.products WHERE id = 'aaaaaaaa-0000-0000-0000-000000000001';
SELECT count(*) AS products_after_delete FROM public.products;   -- [1]의 products_before와 같음

-- [7] ALTER / DROP 시연
ALTER TABLE public.products ADD COLUMN category VARCHAR(50);
SELECT column_name FROM information_schema.columns
WHERE table_name = 'products' AND column_name = 'category';          -- 추가됨
ALTER TABLE public.products DROP COLUMN category;
SELECT column_name FROM information_schema.columns
WHERE table_name = 'products' AND column_name = 'category';          -- 비어 있음 (삭제됨)

CREATE TABLE public.tmp_demo (id INT PRIMARY KEY);
DROP TABLE public.tmp_demo;