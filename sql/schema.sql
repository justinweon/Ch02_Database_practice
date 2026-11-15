-- 1. 기존 테이블이 있다면 막내부터 역순으로 깨끗이 삭제하기
DROP TABLE IF EXISTS public.order_items CASCADE;
DROP TABLE IF EXISTS public.orders CASCADE;
DROP TABLE IF EXISTS public.products CASCADE;
DROP TABLE IF EXISTS public.user_details CASCADE;

-- 2. 회원 프로필 테이블 만들기
CREATE TABLE public.user_details (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role VARCHAR(20) NOT NULL DEFAULT 'buyer' CHECK (role IN ('buyer', 'seller', 'admin')),
    mobile VARCHAR(30),
    email VARCHAR(255),
    address TEXT,
    city VARCHAR(100),
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW()),
    modified_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW()),
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 3. 상품 테이블 만들기
CREATE TABLE public.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    seller_id UUID NOT NULL REFERENCES public.user_details(id) ON DELETE RESTRICT,
    name VARCHAR(255) NOT NULL,
    price INT NOT NULL CHECK (price >= 0),
    description TEXT,
    stock_quantity INT NOT NULL DEFAULT 100 CHECK (stock_quantity >= 0),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW()),
    modified_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW()),
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- 4. 주문 테이블 만들기
CREATE TABLE public.orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    buyer_id UUID NOT NULL REFERENCES public.user_details(id) ON DELETE RESTRICT,
    status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'completed', 'cancelled')),
    total_amount INT NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW()),
    modified_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW())
);

-- 5. 주문 상세 테이블 만들기 (주문 1개에 여러 상품이 담길 수 있음)
CREATE TABLE public.order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price INT NOT NULL CHECK (unit_price >= 0),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT TIMEZONE('utc'::text, NOW())
);

-- 6. [ALTER] 테이블 구조 변경
-- 6-1. 상품 이름이 공백만으로 이뤄지지 않도록 제약 추가
ALTER TABLE public.products
    ADD CONSTRAINT chk_products_name_not_blank CHECK (length(btrim(name)) > 0); --앞뒤 공백을 떼고도 글자가 1개 이상 있어야 한다"는 규칙

-- 6-2. FK 컬럼 인덱스 (조회 속도) 인덱스는 "찾아보기"
CREATE INDEX idx_products_seller_id     ON public.products(seller_id);
CREATE INDEX idx_orders_buyer_id        ON public.orders(buyer_id);
CREATE INDEX idx_order_items_order_id   ON public.order_items(order_id);
CREATE INDEX idx_order_items_product_id ON public.order_items(product_id);

-- 6-3. modified_at 자동 갱신 트리거 (수정할 때마다 시간을 현재로 바꿈)
CREATE OR REPLACE FUNCTION public.set_modified_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.modified_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_user_details_modified BEFORE UPDATE ON public.user_details
    FOR EACH ROW EXECUTE FUNCTION public.set_modified_at();
CREATE TRIGGER trg_products_modified BEFORE UPDATE ON public.products
    FOR EACH ROW EXECUTE FUNCTION public.set_modified_at();
CREATE TRIGGER trg_orders_modified BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.set_modified_at();

-- 7. [트랜잭션 RPC 함수] 원자적 주문 처리
-- 주문 생성 + 영수증 생성 + 재고 차감을 단일 트랜잭션으로 처리
-- 성공 시 자동 COMMIT, 중간 실패 시 전체 자동 ROLLBACK
CREATE OR REPLACE FUNCTION public.create_order_transaction(
    p_product_id UUID,
    p_quantity INT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_buyer_id UUID;
    v_buyer_role VARCHAR;
    v_product_price INT;
    v_stock_quantity INT;
    v_total_amount INT;
    v_order_id UUID;
    v_order_item_id UUID;
BEGIN
    -- [검사 1] 로그인한 사람인지 확인
    v_buyer_id := auth.uid();
    IF v_buyer_id IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- [검사 2] 구매자(buyer)인지 확인
    SELECT role INTO v_buyer_role FROM public.user_details WHERE id = v_buyer_id;
    IF v_buyer_role != 'buyer' THEN
        RAISE EXCEPTION '구매자(buyer)만 주문할 수 있습니다.';
    END IF;

    -- [검사 3] 수량이 1개 이상인지 확인
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION '주문 수량은 1개 이상이어야 합니다.';
    END IF;

    -- [검사 4] 상품 가격과 재고 확인
    SELECT price, stock_quantity INTO v_product_price, v_stock_quantity
    FROM public.products
    WHERE id = p_product_id AND deleted_at IS NULL
    FOR UPDATE;

    IF v_product_price IS NULL THEN
        RAISE EXCEPTION '상품을 찾을 수 없거나 이미 삭제된 상품입니다.';
    END IF;

    IF v_stock_quantity < p_quantity THEN
        RAISE EXCEPTION '재고 부족! (현재 재고: %, 요청 수량: %)', v_stock_quantity, p_quantity;
    END IF;

    v_total_amount := v_product_price * p_quantity;

    -- 📝 [일 1] 주문서 쓰기
    INSERT INTO public.orders (buyer_id, status, total_amount)
    VALUES (v_buyer_id, 'pending', v_total_amount)
    RETURNING id INTO v_order_id;

    -- 🧾 [일 2] 영수증 쓰기
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_product_price)
    RETURNING id INTO v_order_item_id;

    -- 🥟 [일 3] 재고 차감
    UPDATE public.products
    SET stock_quantity = stock_quantity - p_quantity
    WHERE id = p_product_id;

    -- 🟢 3가지 모두 성공 -> 자동 COMMIT!
    RETURN jsonb_build_object(
        'success', true,
        'order_id', v_order_id,
        'order_item_id', v_order_item_id,
        'quantity', p_quantity,
        'total_amount', v_total_amount,
        'remaining_stock', v_stock_quantity - p_quantity
    );

EXCEPTION
    WHEN OTHERS THEN
        -- 🔴 실패 -> 전부 자동 ROLLBACK!
        RAISE EXCEPTION '주문 실패로 전체 롤백: %', SQLERRM;
END;
$$;

-- 7-2. [취소 트랜잭션] 주문 취소 + 재고 복구를 한 번에 처리
CREATE OR REPLACE FUNCTION public.cancel_order_transaction(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 내 주문인지 확인하고, 다른 사람이 동시에 못 건드리게 잠금
    SELECT status INTO v_status
    FROM public.orders
    WHERE id = p_order_id AND buyer_id = auth.uid()
    FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION '주문을 찾을 수 없습니다.';
    END IF;

    IF v_status <> 'pending' THEN
        RAISE EXCEPTION 'pending 상태의 주문만 취소할 수 있습니다.';
    END IF;

    -- 일 1: 주문 상태를 취소로 변경
    UPDATE public.orders SET status = 'cancelled' WHERE id = p_order_id;

    -- 일 2: 창고에 물건 되돌려 놓기
    UPDATE public.products p
    SET stock_quantity = p.stock_quantity + oi.quantity
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id AND p.id = oi.product_id;

    RETURN jsonb_build_object(
        'success', true,
        'order_id', p_order_id,
        'status', 'cancelled'
    );
END;
$$;

-- 8. [롤백 검증 함수] 중간에 일부러 실패시켜 앞의 INSERT까지 취소되는지 확인
-- 순서: 주문서 INSERT(성공) → 영수증 INSERT(quantity=0이라 CHECK 위반으로 실패)
--       → 이미 쓴 주문서까지 전부 ROLLBACK
CREATE OR REPLACE FUNCTION public.test_transaction_rollback(
    p_product_id UUID,
    p_quantity INT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_order_id UUID;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION '로그인이 필요합니다.';
    END IF;

    -- 1) 주문서를 쓴다 (여기까지는 성공)
    INSERT INTO public.orders (buyer_id, status, total_amount)
    VALUES (auth.uid(), 'pending', 99999)
    RETURNING id INTO v_order_id;

    -- 2) 영수증을 쓰다가 실패! quantity가 0이면 CHECK(quantity > 0)에 걸림
    INSERT INTO public.order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, 0, 1);

    -- 여기는 실행되지 않음
    RETURN jsonb_build_object('success', true);
END;
$$;

-- 9. [RPC 권한] 로그인 안 한 사람(anon)은 호출 금지, 로그인한 사람만 허용. REVOKE는 "열쇠 회수", GRANT는 "열쇠 주기"
REVOKE EXECUTE ON FUNCTION public.create_order_transaction(UUID, INT)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.cancel_order_transaction(UUID)       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.test_transaction_rollback(UUID, INT) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_order_transaction(UUID, INT)  TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_order_transaction(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.test_transaction_rollback(UUID, INT) TO authenticated;