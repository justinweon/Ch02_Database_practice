
from datetime import datetime, timezone

from user_details import UserService

class ProductService:
    def __init__(self, supabase):
        self.supabase = supabase
        self.user_service = UserService(supabase)

    def get_current_profile(self):
        return self.user_service.get_profile()

    def is_seller(self):
        profile = self.get_current_profile()
        return profile  is not None and profile ['role'] == 'seller'

    def create_product(self, name, price, description = None):
        if not self.is_seller():
            raise PermissionError("판매자만 상품을 등록할 수 있습니다.")

        profile = self.get_current_profile()
        # Implementation for creating a product would go here
        
        response = (
            self.supabase.table("products")
            .insert({
                "name": name,
                "price": price,
                "description": description,
                "seller_id": profile["id"] #상품을 만들 때 판매자 ID를 직접 입력하지 않고, 현재 로그인한 판매자의 ID를 자동으로 넣는 것
            }).execute()

            )
        return response.data

    def get_product(self, product_id):
        response = (
            self.supabase.table("products")
            .select("*")
            .eq("id",product_id)
            .maybe_single()
        ).execute()
        return response.data

    def get_products(self):
        response = (
            self.supabase.table("products")
            .select("*")
            .is_("deleted_at", "null")
            .execute()
        )
        return response.data

    def update_product(self, product_id, name=None, price=None, description=None):
        profile = self.get_current_profile()

        product = self.get_product(product_id)

        if product is None:
            raise ValueError ("상품을 찾을 수 없습니다")

        if product["seller_id"] != profile["id"]:
            raise PermissionError ("내가 등록한 상품만 수정할 수 있습니다.")

        update_data = {}

        if name is not None:
            update_data["name"]=name

        if price is not None:
            update_data["price"] = price

        if description is not None:
            update_data["description"] = description

        response = (
            self.supabase.table("products")
            .update(update_data)
            .eq("id", product_id)
            .execute()
        )
        return response.data

    def delete_product(self, product_id):
        profile = self.get_current_profile()
        product = self.get_product(product_id)

        if product is None:
            raise ValueError ("상품을 찾을 수 없습니다.")

        if product["seller_id"] != profile["id"]:
            raise PermissionError ("내가 등록한 상품만 삭제할 수 있습니다.")

        response = (
            self.supabase.table("products")
            .update({
                "deleted_at": datetime.now().isoformat()
            })
        .eq("id", product_id)
        .execute()
        )
        return response.data