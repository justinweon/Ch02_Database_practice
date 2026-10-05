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

-- 6. [ALTER] 테이블 구조 변경 예시 (과제 ALTER 조건 충족!)
ALTER TABLE public.products
    ADD COLUMN IF NOT EXISTS updated_memo TEXT;

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

-- 8. [롤백 검증 함수] 일부러 에러를 내서 ROLLBACK 확인
CREATE OR REPLACE FUNCTION public.test_transaction_rollback(
    p_product_id UUID,
    p_quantity INT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_buyer_id UUID;
    v_order_id UUID;
BEGIN
    v_buyer_id := auth.uid();

    -- 주문서를 살짝 썼다가...
    INSERT INTO public.orders (buyer_id, status, total_amount)
    VALUES (v_buyer_id, 'pending', 99999)
    RETURNING id INTO v_order_id;

    -- 💥 일부러 에러 발생! -> 방금 쓴 주문서도 자동 ROLLBACK!
    RAISE EXCEPTION '테스트용 강제 에러! orders 테이블 삽입이 롤백되어야 합니다.';
END;
$$;