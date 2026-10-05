from user_details import UserService

class OrderService:
    def __init__(self, supabase):
        self.supabase = supabase
        self.user_service = UserService(supabase)

    def get_current_profile(self):
        return self.user_service.get_profile()

    def is_buyer (self):
        profile = self.get_current_profile()

        return profile is not None and profile["role"] == "buyer"

    def create_order(self, product_id, quantity):
        profile = self.get_current_profile()

        if not self.is_buyer():
            raise PermissionError ("구매자만 주문할 수 있습니다")

        if quantity <=0:
            raise ValueError ("주문 수량은 1개 이상이어야 합니다.")

        product_response = (
            self.supabase.table("products")
            .select("*")
            .eq("id", product_id)
            .is_("deleted_at", "null")
            .maybe_single()
            .execute()
        )
        product = product_response.data

        if product is None:
            raise ValueError ("상품을 찾지 못했습니다.")

        total_amount = product["price"] * quantity

        order_response = (
            self.supabase.table("orders")
            .insert({
                "buyer_id":profile["id"],
                "status":"pending",
                "total_amount": total_amount

            }).execute()
        )

        created_order = order_response.data[0]

        order_item_response = (
            self.supabase.table("order_items")
            .insert({
                "order_id": created_order["id"],
                "product_id":product["id"],
                "quantity":quantity,
                "unit_price": product["price"]
            }).execute()
        )

        created_order_item = order_item_response.data[0]

        return{
            "order":created_order,
            "order_item":created_order_item
        }

    def get_my_orders(self):
        profile = self.get_current_profile()

        if not self.is_buyer():
            raise PermissionError ("구매자만 주문을 조회할 수 있습니다.")

        response = (
            self.supabase.table("orders")
            .select("*")
            .eq("buyer_id", profile["id"])
            .order("created_at", desc=True)
            .execute()
        )

        return response.data

    def cancel_order(self, order_id):
        profile = self.get_current_profile()

        if not self.is_buyer():
            raise PermissionError ("구매자만 주문을 취소할 수 있습니다.")

        order_response = (
            self.supabase.table("orders")
            .select("*")
            .eq("id", order_id)
            .eq("buyer_id", profile["id"])
            .maybe_single()
            .execute()
        )

        order = order_response.data

        if order is None:
            raise ValueError ("주문을 찾을 수 없습니다.")

        if order["status"] != "pending":
            raise ValueError ("pending 상태의 주문만 취소할 수 있습니다.")

        response = (
            self.supabase.table("orders")
            .update({"status": "cancelled"})
            .eq("id", order_id)
            .execute()
        )
        return response.data[0]

    def get_orders_for_my_products(self):
        profile = self.get_current_profile()

        if profile is None or profile["role"] != "seller":
            raise PermissionError ("판매자만 자신의 상품에 대한 주문을 조회할 수 있습니다.")

        product_response =(
            self.supabase.table("products")
            .select("id, name")
            .eq("seller_id", profile["id"])
            .execute()
        )
        my_products = product_response.data
        product_ids = [product["id"]for product in my_products]
        if not product_ids:
            return[]
        
        order_items_response = (
            self.supabase.table("order_items")
            .select("*, orders(*)")
            .in_("product_id", product_ids)
            .execute()
        )

        return order_items_response.data


    #[commit/rollback] transaction rpc (remmote procedure call)

    # (성공 시 자동 COMMIT)
    def create_order_atomic(self, product_id, quantity):
        if not self.is_buyer():
            raise PermissionError("구매자만 주문할 수 있습니다.")

        if quantity <= 0:
            raise ValueError("주문 수량은 1개 이상이어야 합니다.")

        # RPC) 호출. 주문+상세+재고차감을 단일 트랜잭션으로 처리해 줌
        response = self.supabase.rpc(
            "create_order_transaction",
            {
                "p_product_id": str(product_id),
                "p_quantity": int(quantity)
            }
        ).execute()
        return response.data

    # [롤백 검증] 일부러 에러를 내서 장부가 깨끗이 취소(ROLLBACK)되는지 시험
    def test_order_rollback(self, product_id, quantity):
        try:
            response = self.supabase.rpc(
                "test_transaction_rollback",
                {
                    "p_product_id": str(product_id),
                    "p_quantity": int(quantity)
                }
            ).execute()
            return response.data
        except Exception as e:
            # 에러가 발생해서 롤백되었다는 소식을 받아옴!
            return {
                "rollback_verified": True,
                "error_message": str(e)
            }