import os, uuid, bcrypt
from datetime import datetime, timedelta
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from sqlalchemy.orm import Session
from jose import JWTError, jwt
from database import get_db
from models import User
from schemas import UserRegister, UserOut, Token

router = APIRouter()

SECRET_KEY = os.environ.get("SECRET_KEY", "fallback_dev_secret_change_in_prod")
ALGORITHM  = "HS256"
EXPIRE_MIN = int(os.environ.get("ACCESS_TOKEN_EXPIRE_MINUTES", "10080"))

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login", auto_error=False)

def hash_pw(pw: str) -> str:
    return bcrypt.hashpw(pw.encode("utf-8")[:72], bcrypt.gensalt()).decode("utf-8")

def verify_pw(plain: str, hashed: str) -> bool:
    return bcrypt.checkpw(plain.encode("utf-8")[:72], hashed.encode("utf-8"))

def create_token(user_id: str) -> str:
    expire = datetime.utcnow() + timedelta(minutes=EXPIRE_MIN)
    return jwt.encode({"sub": user_id, "exp": expire}, SECRET_KEY, algorithm=ALGORITHM)

def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db)
) -> User:
    if not token:
        raise HTTPException(status_code=401, detail="Not authenticated")
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        user_id: str = payload.get("sub")
        if not user_id:
            raise HTTPException(status_code=401, detail="Invalid token")
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
    return user

@router.post("/register", response_model=Token)
def register(data: UserRegister, db: Session = Depends(get_db)):
    if not data.username or len(data.username.strip()) < 3:
        raise HTTPException(status_code=400, detail="Username must be at least 3 characters")
    if not data.password or len(data.password) < 4:
        raise HTTPException(status_code=400, detail="Password must be at least 4 characters")
    username = data.username.strip().lower()
    if db.query(User).filter(User.username == username).first():
        raise HTTPException(status_code=400, detail="Username already taken")
    user = User(
        id=str(uuid.uuid4())[:12],
        username=username,
        email=data.email or None,
        hashed_password=hash_pw(data.password),
        is_guest=False,
    )
    db.add(user); db.commit(); db.refresh(user)
    return Token(access_token=create_token(user.id), token_type="bearer", user=UserOut.from_orm(user))

@router.post("/login", response_model=Token)
def login(form: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    username = form.username.strip().lower()
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_pw(form.password, user.hashed_password):
        raise HTTPException(status_code=401, detail="Incorrect username or password")
    return Token(access_token=create_token(user.id), token_type="bearer", user=UserOut.from_orm(user))

@router.post("/guest", response_model=Token)
def guest_login(db: Session = Depends(get_db)):
    guest_id = str(uuid.uuid4())[:12]
    user = User(
        id=guest_id,
        username=f"guest_{guest_id}",
        hashed_password=hash_pw(guest_id),
        is_guest=True,
    )
    db.add(user); db.commit(); db.refresh(user)
    return Token(access_token=create_token(user.id), token_type="bearer", user=UserOut.from_orm(user))

@router.get("/me", response_model=UserOut)
def me(user: User = Depends(get_current_user)):
    return user
