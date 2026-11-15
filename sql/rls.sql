-- 누가 어떤줄을 볼 수 있는지 규칙을 적어둠 

-- ==========================================================
-- RLS (Row Level Security) 정책
-- schema.sql 실행 후 실행하세요.
-- ==========================================================

-- 0. 기존 정책 전부 제거 (대시보드에서 만든 것이 남아 있어도 충돌하지 않도록)
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT policyname, tablename FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename IN ('user_details', 'products', 'orders', 'order_items')
    LOOP
        EXECUTE format('DROP POLICY %I ON public.%I', r.policyname, r.tablename);
    END LOOP;
END $$;

-- 1. 4개 테이블 모두 RLS 켜기 (이미 켜져 있어도 문제 없음)
ALTER TABLE public.user_details ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items  ENABLE ROW LEVEL SECURITY;

-- 2. 헬퍼 함수: "이 주문에 내 상품이 들어 있나?"
--    orders 정책이 order_items를 직접 조회하면 서로 꼬여 무한 반복 에러가 나므로,
--    RLS를 우회하는 함수(SECURITY DEFINER)로 대신 확인합니다.
CREATE OR REPLACE FUNCTION public.is_seller_of_order(p_order_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.order_items oi
        JOIN public.products p ON p.id = oi.product_id
        WHERE oi.order_id = p_order_id AND p.seller_id = auth.uid()
    );
$$;
REVOKE EXECUTE ON FUNCTION public.is_seller_of_order(UUID) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_seller_of_order(UUID) TO authenticated;

-- 3. user_details: 내 프로필만
CREATE POLICY user_details_select_own ON public.user_details
    FOR SELECT TO authenticated USING (id = auth.uid());

CREATE POLICY user_details_insert_own ON public.user_details
    FOR INSERT TO authenticated
    WITH CHECK (id = auth.uid() AND role IN ('buyer', 'seller'));   -- admin 가입 차단

CREATE POLICY user_details_update_own ON public.user_details
    FOR UPDATE TO authenticated
    USING (id = auth.uid()) WITH CHECK (id = auth.uid());

CREATE POLICY user_details_delete_own ON public.user_details
    FOR DELETE TO authenticated USING (id = auth.uid());

-- role, id는 수정 못 하게 컬럼 단위로 권한 제한
REVOKE UPDATE ON public.user_details FROM authenticated;
GRANT  UPDATE (mobile, email, address, city, first_name, last_name)
    ON public.user_details TO authenticated;

-- 4. products: 조회는 모두, 쓰기는 내가 판매자일 때 내 상품만 (DELETE 정책 없음 = soft delete만)
CREATE POLICY products_select ON public.products
    FOR SELECT TO authenticated
    USING (deleted_at IS NULL OR seller_id = auth.uid());

CREATE POLICY products_insert_seller ON public.products
    FOR INSERT TO authenticated
    WITH CHECK (
        seller_id = auth.uid()
        AND EXISTS (SELECT 1 FROM public.user_details u
                    WHERE u.id = auth.uid() AND u.role = 'seller')
    );

CREATE POLICY products_update_own ON public.products
    FOR UPDATE TO authenticated
    USING (seller_id = auth.uid()) WITH CHECK (seller_id = auth.uid());

-- 5. orders: 구매자 본인 + 내 상품이 담긴 주문(판매자)만 조회
--    INSERT/UPDATE/DELETE 정책 없음 → 주문 생성/취소는 RPC 함수로만 가능
CREATE POLICY orders_select ON public.orders
    FOR SELECT TO authenticated
    USING (buyer_id = auth.uid() OR public.is_seller_of_order(id));

-- 6. order_items: 내 주문의 항목 또는 내 상품의 항목만 조회
CREATE POLICY order_items_select ON public.order_items
    FOR SELECT TO authenticated
    USING (
        EXISTS (SELECT 1 FROM public.orders o
                WHERE o.id = order_id AND o.buyer_id = auth.uid())
        OR EXISTS (SELECT 1 FROM public.products p
                   WHERE p.id = product_id AND p.seller_id = auth.uid())
    );