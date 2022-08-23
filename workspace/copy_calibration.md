
/**
 * 
 * 
 * 
 * 相机标定，张正友标定算法实现
 * 
 * by atway 2020-05-10
 * 
 * tianyongzhai@gmail.com
 * 
 * 
 * 
 * 
 */

#include <ceres/ceres.h>
#include "calibration.h"
#include "ceres_costfun.h"
#include <opencv2/calib3d.hpp>
#include <opencv2/core/eigen.hpp>
#include <set>

#include <iostream>


/*
 * 归一化
 scale.jpg

 */
void normal ( MatrixXd& P, Matrix3d& T )
// P [96 x 3]  T [3 x 3]
{
    // 求平均.jpg
    double cx = P.col ( 0 ).mean(); 
    double cy = P.col ( 1 ).mean();
    int N     = P.rows(); // 96

    P.array().col ( 0 ) -= cx;
    P.array().col ( 1 ) -= cy;

    double stdx = sqrt ( ( P.col ( 0 ).transpose() * P.col ( 0 ) ).sum() / N); // https://eigen.tuxfamily.org/dox/group__TutorialReductionsVisitorsBroadcasting.html
    /* Notes    
    auto a = P.col ( 0 ).transpose() * P.col ( 0 );
    std::cout << a.mean() << std::endl; // reduction 操作，纯属为了mat 变成 一个scalar而已，与mean 无关，你用sum也行
    std::cout << a.sum() << std::endl;
    std::cout << a.prod() << std::endl; */


    double stdy = sqrt ( ( P.col ( 1 ).transpose() * P.col ( 1 ) ).sum() / N); // 我觉得是要除以N，原来没有除以N

 

    double sqrt_2 = sqrt ( 2 );
    double scalex = sqrt_2 / stdx;
    double scaley = sqrt_2 / stdy;

    P.array().col(0) *= scalex;
    P.array().col(1) *= scalex;
    
    T << scalex, 0, -scalex*cx,
    0, scaley, -scaley*cy,
    0, 0, 1;
    
    
}


VectorXd solveHomographyDLT ( MatrixXd& srcNormal, MatrixXd& dstNormal )
{

    int n = srcNormal.rows();
    // 2. DLT
    MatrixXd input ( 2*n, 9 );

    for ( int i=0; i<n; ++i ) {

        input ( 2*i, 0 ) = 0.;
        input ( 2*i, 1 ) = 0.;
        input ( 2*i, 2 ) = 0.;
        input ( 2*i, 3 ) = srcNormal ( i, 0 );
        input ( 2*i, 4 ) = srcNormal ( i, 1 );
        input ( 2*i, 5 ) = 1.;
        input ( 2*i, 6 ) = -srcNormal ( i, 0 ) * dstNormal ( i, 1 );
        input ( 2*i, 7 ) = -srcNormal ( i, 1 ) * dstNormal ( i, 1 );
        input ( 2*i, 8 ) = -dstNormal ( i, 1 );

        input ( 2*i+1, 0 ) = srcNormal ( i, 0 );
        input ( 2*i+1, 1 ) = srcNormal ( i, 1 );
        input ( 2*i+1, 2 ) = 1.;
        input ( 2*i+1, 3 ) = 0.;
        input ( 2*i+1, 4 ) = 0.;
        input ( 2*i+1, 5 ) = 0.;
        input ( 2*i+1, 6 ) = -srcNormal ( i, 0 ) * dstNormal ( i, 0 );
        input ( 2*i+1, 7 ) = -srcNormal ( i, 1 ) * dstNormal ( i, 0 );
        input ( 2*i+1, 8 ) = -dstNormal ( i, 0 );
    }

    // 3. SVD分解
    JacobiSVD<MatrixXd> svdSolver ( input, ComputeThinU | ComputeThinV );
    MatrixXd V = svdSolver.matrixV();

    //double s = V.rightCols ( 1 ) ( 8 );
    //MatrixXd M = V.rightCols ( 1 ) /s;

    return V.rightCols ( 1 ); // pick the last 1 column
}

bool findHomography ( std::vector<Eigen::Vector2d>& srcPoints, std::vector<Eigen::Vector2d>& dstPoints, Eigen::Matrix3d& H, bool isNormal )
{
    /* 
    find_H.jpg
    
    世界坐标 映射到 像素坐标
    抽象为
    src坐标  映射到 dst坐标
     */

    assert ( srcPoints.size() == dstPoints.size() );
    int n = srcPoints.size(); // 一张图有96个点

    // 引入齐次坐标，即原来是（u,v）---> (u,v,1)  原来是(x,y) -->(x,y,1)
    MatrixXd srcNormal ( n, 3 );
    MatrixXd dstNormal ( n, 3 );

    for ( int i=0; i<n; ++i ) {

        srcNormal ( i, 0 ) = srcPoints[i] ( 0 );
        srcNormal ( i, 1 ) = srcPoints[i] ( 1 );
        srcNormal ( i, 2 ) = 1.0;

        dstNormal ( i, 0 ) = dstPoints[i] ( 0 );
        dstNormal ( i, 1 ) = dstPoints[i] ( 1 );
        dstNormal ( i, 2 ) = 1.0;
    }

    // 1. 归一化

    Matrix3d srcT, dstT;
    if(isNormal) {
        //优化前
        normal ( srcNormal, srcT ); // srcT 为 3x3 的用来normalize的矩阵
        normal ( dstNormal, dstT ); // dstT 为 3x3 的用来normalize的矩阵
    }


    // 2. DLT (SVD trick)
    VectorXd v = solveHomographyDLT(srcNormal, dstNormal);

    // std::cout << "v = " << v << std::endl;

    // 3.优化
    {

        ceres::Problem optimizationProblem;
        for(int i=0; i<n; ++i)
        {
            optimizationProblem.AddResidualBlock(
                new ceres::AutoDiffCostFunction<HOMOGRAPHY_COST, 1, 9>(
                    new HOMOGRAPHY_COST(srcNormal(i, 0), srcNormal(i, 1), dstNormal(i, 0), dstNormal(i, 1))
                ),
                nullptr,

                v.data()
            );
        }

        ceres::Solver::Options options;
        options.minimizer_progress_to_stdout = false;
        options.trust_region_strategy_type = ceres::TrustRegionStrategyType::LEVENBERG_MARQUARDT;
        ceres::Solver::Summary summary;
        ceres::Solve(options, &optimizationProblem, &summary);

        std::cout << summary.BriefReport() << std::endl;

        //std::cout <<"v = " << v << std::endl;


    }


    Matrix3d M ;
    M << v(0), v(1), v(2),
    v(3), v(4), v(5),
    v(6), v(7), v(8);
    


    // 4. 反计算H
    if(isNormal) {
        H = dstT.inverse() * M * srcT;
        H.array() /= H(8);
    } else {
        H = M;
        H.array() /= H(8);
    }
    //std::cout << "H " << H;

    return true;
}


inline int rand_int (void)
{
    return std::rand();
}
bool findHomographyByOpenCV(std::vector<Eigen::Vector2d>& srcPoints, std::vector<Eigen::Vector2d>& dstPoints, Eigen::Matrix3d& H) {

    std::vector<cv::Point2f> objectPoints, imagePoints;

    for(int i=0; i<srcPoints.size(); ++i) {
        objectPoints.push_back(cv::Point2f(srcPoints[i](0), srcPoints[i](1)));
        imagePoints.push_back(cv::Point2f(dstPoints[i](0), dstPoints[i](1)));
    }

    cv::Mat hMat = findHomography(objectPoints, imagePoints, cv::RANSAC);

    cv::cv2eigen(hMat, H);

}


bool findHomographyByRansac ( std::vector<Eigen::Vector2d>& srcPoints, std::vector<Eigen::Vector2d>& dstPoints, Eigen::Matrix3d& H )
{

    assert ( srcPoints.size() == dstPoints.size() );

    MatrixXd srcNormal ( srcPoints.size(), 3 );
    MatrixXd dstNormal ( dstPoints.size(), 3 );

    for ( int i=0; i<srcPoints.size(); ++i ) {

        srcNormal ( i, 0 ) = srcPoints[i] ( 0 );
        srcNormal ( i, 1 ) = srcPoints[i] ( 1 );
        srcNormal ( i, 2 ) = 1.0;

        dstNormal ( i, 0 ) = dstPoints[i] ( 0 );
        dstNormal ( i, 1 ) = dstPoints[i] ( 1 );
        dstNormal ( i, 2 ) = 1.0;
    }

    // 归一化

    Matrix3d srcT, dstT;
    normal ( srcNormal, srcT );
    normal ( dstNormal, dstT );


    //Ransac 去除外点
    int n = srcPoints.size();
    double p=0.99, w =0.5;
    int s=4;
    int maxN = log ( 1-p ) / log ( 1-pow ( ( 1-w ),s ) ) + 1;
    double threshold = 0.2;

    int bestCount=0;
    std::vector<int> inlinersMask ( n );
    for ( int i=0; i<maxN; ++i )
    {

        cv::RNG rng ( cv::getTickCount() );

        std::set<int> indexes;
        while(indexes.size() < 4){
           indexes.insert( rand_int() % n);
        }

        Matrix3d M;
        {
            // 计算H 点法
            MatrixXd _srcNormal ( s, 3 );
            MatrixXd _dstNormal ( s, 3 );
            std::set<int>::const_iterator iter = indexes.cbegin();
            for ( int j=0; j<s; j++, iter++ ) {

                _srcNormal ( j, 0 ) = srcNormal ( *iter, 0 );
                _srcNormal ( j, 1 ) = srcNormal ( *iter, 1 );
                _srcNormal ( j, 2 ) = 1.0;

                _dstNormal ( j, 0 ) = dstNormal ( *iter, 0 );
                _dstNormal ( j, 1 ) = dstNormal ( *iter, 1 );
                _dstNormal ( j, 2 ) = 1.0;
            }


            VectorXd v = solveHomographyDLT ( _srcNormal, _dstNormal );
            M << v(0), v(1), v(2),
            v(3), v(4), v(5),
            v(6), v(7), v(8);
            M.array() /= v(8);
        }

        // 统计
        std::vector<int> _inliners ( n );

        {
            MatrixXd _srcNormal =  srcNormal*M;
            double _x, _y, _d_2;
            double _threshold_2 = threshold*threshold;
            int count=0;
            for ( int j=0; j<n; ++j ) {

                _x = _srcNormal ( j, 0 ) / _srcNormal ( j, 2 );
                _y = _srcNormal ( j, 1 ) / _srcNormal ( j, 2 );
                _d_2 = pow ( _x-dstNormal ( j, 0 ), 2 ) + pow ( _y-dstNormal ( j, 1 ), 2 );
                if ( _d_2 <= _threshold_2 ) {
                    _inliners[j] = 1;
                    count ++;
                } else {
                    _inliners[j] = 0;
                }

            }

            if ( bestCount < count ) {
                bestCount = count;
                inlinersMask.assign ( _inliners.begin(), _inliners.end() );
            }
        }


    }
    //求解

    Matrix3d M;
    {
        // 计算H 点法
        MatrixXd _srcNormal ( bestCount, 3 );
        MatrixXd _dstNormal ( bestCount, 3 );

        int temp=0;
        for ( int j=0; j<n; ++j ) {
            if ( inlinersMask[j]==0 )
                continue;

            _srcNormal ( temp, 0 ) = srcNormal ( j, 0 );
            _srcNormal ( temp, 1 ) = srcNormal ( j, 1 );
            _srcNormal ( temp, 2 ) = 1.0;

            _dstNormal ( temp, 0 ) = dstNormal ( j, 0 );
            _dstNormal ( temp, 1 ) = dstNormal ( j, 1 );
            _dstNormal ( temp, 2 ) = 1.0;

            temp++;
        }


        VectorXd v = solveHomographyDLT ( _srcNormal, _dstNormal );
        M << v(0), v(1), v(2),
        v(3), v(4), v(5),
        v(6), v(7), v(8);
        M.array() /= v(8);
    }

    // 反计算H

    H = dstT.inverse() * M * srcT;

    return true;

}

/**
 *  Vij=[hi1hj1  hi1hj2+hi2hj1  hi2hj2  hi3hj1+hi1hj3  hi3hj2+hi2hj3  hi3hj3]
 * @param H
 * @param i
 * @param j
 * @return
 */
VectorXd getVector(const Matrix3d& H, int i, int j)
{
    i -= 1;
    j -= 1;
    VectorXd v(6);
    v << H(0, i)*H(0, j), H(0, i)*H(1, j) + H(1, i)*H(0, j), H(1, i)*H(1, j), H(2, i)*H(0, j) + H(0, i)*H(2, j), H(2, i)*H(1, j) + H(1, i)*H(2, j), H(2, i)*H(2, j);
    return v;
}

/**
 *
 * 计算相机内参初始值, 求解Vb =0; 并计算K矩阵
 *
 */
Matrix3d solveInitCameraIntrinsic(std::vector<Matrix3d>& homos)
{
    int n = homos.size();
    // Vb = 0
    MatrixXd V(2*n, 6);
    for(int i=0; i<n; ++i)
    {
        VectorXd v1 = getVector(homos[i], 1, 2);
        VectorXd v11 = getVector(homos[i], 1, 1);
        VectorXd v22 = getVector(homos[i], 2, 2);
        VectorXd v2 = v11 - v22;

        for(int j=0; j<6; ++j)
        {
            V(2*i, j) = v1(j);
            V(2*i+1, j) = v2(j);
        }
    }

    //SVD 分解
    JacobiSVD<MatrixXd> svdSolver (V, ComputeThinV);
    MatrixXd v = svdSolver.matrixV();
    MatrixXd b = v.rightCols(1);

    std::cout <<"b = " << b << std::endl;


    // 求解内参 fx fy c uo v0
    double B11 = b(0), B12 = b(1), B22 = b(2), B13 = b(3), B23 = b(4), B33 = b(5);
    double v0 = (B12*B13-B11*B23) / (B11*B22-B12*B12);
    double s = B33-(B13*B13+v0*(B12*B13-B11*B23)) / B11;
    double fx = sqrt(s/B11);
    double fy = sqrt(s*B11 / (B11*B22-B12*B12));
    double c = -B12*fx*fx*fy/s;
    double u0 = c*v0/fx - B13*fx*fx/s;

    Matrix3d K;

    K << fx, c, u0,
    0, fy, v0,
    0, 0, 1;

    return K;
}

/**
 *
 * 计算相机外参初始值
 */
void solveInitCameraExtrinsic(std::vector<Matrix3d>& homos, Matrix3d& K, std::vector<Matrix3d>& RList, std::vector<Vector3d>& tList)
{
    // This is the initial status of the Camera Extrinsic parameter, which needs to be optimzized due to noises.
    // solve_for_R.jpg
    int n = homos.size(); // the number of the images
    Matrix3d kInv = K.inverse(); // e.g. 13 images 
    for (int i=0; i<n; ++i)
    {
        Vector3d r0, r1, r2;
        r0 = kInv*homos[i].col(0); // r0 = lambda K^-1 h0
        r1 = kInv*homos[i].col(1); // r1 = lambda K^-1 h1

        double s0 = sqrt(r0.dot(r0));
        double s1 = sqrt(r1.dot(r1));

        r0.array().col(0) /= s0; // make it unit vector
        r1.array().col(0) /= s1;
        r2 = r0.cross(r1); // r2 = r1 x r2 cross product

        Vector3d t = kInv*homos[i].col(2) / s0; 

        Matrix3d R;
        R.array().col(0) = r0;
        R.array().col(1) = r1;
        R.array().col(2) = r2;

        std::cout <<"R " << R << std::endl;
        std::cout <<"t " << t.transpose() << std::endl;
        RList.push_back(R);
        tList.push_back(t);
    }
}


/**
 * 旋转矩阵转换为旋转向量
 */
Vector3d rotationMatrix2Vector(const Matrix3d& R) 
{

    AngleAxisd r;
    r.fromRotationMatrix(R);
    return r.angle()*r.axis();
}

/**
 * 
 * 旋转向量到旋转矩阵
 */

Matrix3d rotationVector2Matrix(const Vector3d& v)
{

    double s = sqrt(v.dot(v));
    Vector3d axis = v/s;
    AngleAxisd r( s, axis);
    
    return r.toRotationMatrix();
}


void getObjectPoints(const cv::Size& borderSize, const cv::Size2f& squareSize, std::vector<Eigen::Vector3d>& objectPoints) {
    /* 
    以棋盘格左上角为原点，这里我们做一个很特殊的假设，我们去掉z（相当于z=0），只保留x，y。 【为什么呢？】
    
    */
    for(int r=0; r<borderSize.height; ++r)
    {
        for(int c=0; c<borderSize.width; ++c) {
            objectPoints.push_back(Eigen::Vector3d(c*squareSize.width, r*squareSize.height, 0.)); // 所以这里的z = 0。这里我们通过棋盘上角的绝对物理位置来表示objectPoint
        }

    }
}


/**
 * 计算重投影误差
 * @param objectPoints
 * @param imagePoints
 * @param rvecs
 * @param tvecs
 * @param cameraMatrix
 * @param distCoeffs
 * @param perViewErrors
 * @return
 */
double computeReprojectionErrors(const vector<vector<Eigen::Vector3d>>& objectPoints, const vector<vector<Eigen::Vector2d>>& imagePoints, const vector<Eigen::Vector3d>& rvecs, const vector<Eigen::Vector3d>& tvecs, const Eigen::Matrix3d& cameraMatrix, const Eigen::VectorXd& distCoeffs, vector<double>& perViewErrors)
{
    vector<cv::Point2f> imagePoints2;
    int totalPoints = 0;
    double totalErr = 0;
    perViewErrors.resize(objectPoints.size());
    double k1 = distCoeffs(0), k2 = distCoeffs(1), k3 = distCoeffs(4);
    double p1 = distCoeffs(2), p2 = distCoeffs(3);
    double fx = cameraMatrix(0,0), fy = cameraMatrix(1,1);
    double cx = cameraMatrix(0,2), cy = cameraMatrix(1,2);
    for (int i = 0; i < objectPoints.size(); ++i)
    {
       
        Matrix3d R = rotationVector2Matrix(rvecs[i]);
        int n = objectPoints[i].size();
        double _errSum=0;
        for(int j =0; j<n; ++j){
            
              Vector3d cam =  R*objectPoints[i][j]+tvecs[i];
              double xp = cam(0) / cam(2);
              double yp = cam(1) / cam(2);
              
              double r2 = xp*xp + yp*yp;
              double xdis = xp*(1 + k1*r2 + k2*r2*r2 + k3*r2*r2*r2) + 2*p1*xp*yp + p2*(r2 + 2*xp*xp);
              double ydis = yp*(1 + k1*r2 + k2*r2*r2 + k3*r2*r2*r2) + p1*(r2 + 2*yp*yp) + 2*p2*xp*yp;
              double u = fx*xdis+cx;
              double v = fy*ydis+cy;
              
              double _err = sqrt( pow(u - imagePoints[i][j](0), 2) + pow(v - imagePoints[i][j](1), 2));
              
              _errSum += _err;
        }
        
        perViewErrors[i] = _errSum / n;
        totalErr += _errSum;
        totalPoints += n;
    }
    

    return totalErr / totalPoints;
}


/**
 * 鱼眼镜头重投影误差
 * @param objectPoints
 * @param imagePoints
 * @param rvecs
 * @param tvecs
 * @param cameraMatrix
 * @param distCoeffs
 * @param perViewErrors
 * @return
 */
double computeFisherReprojectionErrors(const vector<vector<Eigen::Vector3d>>& objectPoints, const vector<vector<Eigen::Vector2d>>& imagePoints, const vector<Eigen::Vector3d>& rvecs, const vector<Eigen::Vector3d>& tvecs, const Eigen::Matrix3d& cameraMatrix, const Eigen::VectorXd& distCoeffs, vector<double>& perViewErrors)
{
    vector<cv::Point2f> imagePoints2;
    int totalPoints = 0;
    double totalErr = 0;
    perViewErrors.resize(objectPoints.size());
    double k1 = distCoeffs(0);
    double k2 = distCoeffs(1);
    double k3 = distCoeffs(2);
    double k4 = distCoeffs(3);
    double fx = cameraMatrix(0,0), fy = cameraMatrix(1,1);
    double cx = cameraMatrix(0,2), cy = cameraMatrix(1,2);
    for (int i = 0; i < objectPoints.size(); ++i)
    {

        Matrix3d R = rotationVector2Matrix(rvecs[i]);
        int n = objectPoints[i].size();
        double _errSum=0;
        for(int j =0; j<n; ++j){

            Vector3d cam =  R*objectPoints[i][j]+tvecs[i];
            double xp = cam(0) / cam(2);
            double yp = cam(1) / cam(2);

            // 鱼眼镜头模型
            double r_ = sqrt(xp*xp + yp*yp);
            double theta = atan(r_);

            double thera_hat = theta * (1 + k1*pow(theta, 2) + k2*pow(theta, 4) + k3*pow(theta, 6) + k4*pow(theta, 8));

            double xdis = thera_hat*xp / r_;
            double ydis = thera_hat*yp / r_;

            double u = fx*xdis+cx;
            double v = fy*ydis+cy;

            double _err = sqrt( pow(u - imagePoints[i][j](0), 2) + pow(v - imagePoints[i][j](1), 2));

            _errSum += _err;
        }

        perViewErrors[i] = _errSum / n;
        totalErr += _errSum;
        totalPoints += n;
    }


    return totalErr / totalPoints;
}




/**
 * 相机标定
 */
void computeCameraCalibration(std::vector<std::vector<Eigen::Vector2d>>& imagePoints,
                              std::vector<std::vector<Eigen::Vector3d>>& objectPoints, cv::Mat& cameraMatrix, cv::Mat& distCoeffs)
{
    // debug 
    // for (int i = 0; i < imagePoints.size(); ++i){
    //     std::cout << imagePoints[i] << std::endl;
    // }
    std::cout << imagePoints.size() << std::endl;
    
    //

    std::cout << " fit homography ....." << std::endl;
    int n = imagePoints.size();
    std::vector<Eigen::Matrix3d> homos; // 为啥H是3x3.jpg(这里是好多个H mat, 因为我们有18组 uv--xyz)
    for (int i=0; i<n; ++i) // 18张图
    {
        Eigen::Matrix3d H;
        std::vector<Eigen::Vector2d> objectPoints2d;
        for(auto& xy: objectPoints[i]) {
            objectPoints2d.push_back(Eigen::Vector2d(xy(0), xy(1)));
        }
        bool ok = findHomography( objectPoints2d,imagePoints[i], H, true);
        //findHomographyByOpenCV(objectPoints2d,imagePoints[i], H);
        std::cout << H << std::endl;
        homos.push_back(H);
    }
    std::cout << " fit homography finished" << std::endl;

    // 计算相机内参初始值
    std::cout << " solve init camera intrinsic ..." << std::endl;

    Eigen::Matrix3d K = solveInitCameraIntrinsic(homos);

    std::cout << "init k" << K << std::endl;
    // 计算每组的外参（旋转矩阵和平移向量）
    std::vector<Matrix3d> RList;
    std::vector<Vector3d> tList;
    std::cout << " solve init camera extrinsic ..." << std::endl;
    solveInitCameraExtrinsic(homos, K, RList, tList);
    std::cout << " solve init camera extrinsic finished" << std::endl;
    std::vector<Vector3d> rList;
    for(auto& item: RList) { // 13 R in the RList
        Vector3d _r = rotationMatrix2Vector(item);
        rList.push_back(_r);
    }
    std::cout << " solve ceres::Solver::Options ..." << std::endl;

    // 优化算法
    {
        //
        ceres::Problem problem;
        double k[9] = {K(0,0), K(1,1), K(0,2), K(1,2), 0., 0., 0., 0., 0.};


        for(int i=0; i<n; ++i) {


            for(int j=0; j<imagePoints[i].size(); ++j) {
                // 优化参数2->输出的残差数，表示x和y
                // 9 表示 内参4个 畸变系数5个
                // 3 外参，用旋转向量表示，输入需要把旋转矩阵转为旋转向量，再输入
                // 3 外参 平移向量
                ceres::CostFunction* costFunction=new ceres::AutoDiffCostFunction<PROJECT_COST, 2, 9, 3, 3>(
                    new PROJECT_COST(objectPoints[i][j], imagePoints[i][j]));

                problem.AddResidualBlock(costFunction,
                                         nullptr,
                                         k,
                                         rList[i].data(),
                                         tList[i].data()
                                        );

            }
        }
        std::cout << " solve Options ..." << std::endl;

        ceres::Solver::Options options;
        options.minimizer_progress_to_stdout = true;
        //options.linear_solver_type = ceres::DENSE_SCHUR;
        //options.trust_region_strategy_type = ceres::TrustRegionStrategyType::LEVENBERG_MARQUARDT;
        //options.preconditioner_type = ceres::JACOBI;
        //options.sparse_linear_algebra_library_type = ceres::EIGEN_SPARSE;
        ceres::Solver::Summary summary;
        ceres::Solve(options, &problem, &summary);
        std::cout << summary.BriefReport() << std::endl;


        if (!summary.IsSolutionUsable())
        {
            std::cout << "Bundle Adjustment failed." << std::endl;
        }
        else
        {
            //summary.num_
            // Display statistics about the minimization
            std::cout << std::endl
                      << "Bundle Adjustment statistics (approximated RMSE):\n"
                      << " #views: " << n << "\n"
                      << " #residuals: " << summary.num_residuals << "\n"
                      << " #num_parameters: " << summary.num_parameters << "\n"
                      << " #num_parameter_blocks: " << summary.num_parameter_blocks << "\n"
                      << " Initial RMSE: " << std::sqrt(summary.initial_cost / summary.num_residuals) << "\n"
                      << " Final RMSE: " << std::sqrt(summary.final_cost / summary.num_residuals) << "\n"
                      << " Time (s): " << summary.total_time_in_seconds << "\n"
                      << std::endl;

            for(auto& a: k) std::cout << a << " " ;

            //cv::Mat cameraMatrix, distCoeffs;
            //cameraMatrix = (cv::Mat_<double>(3, 3) << k[0], 0.0, k[2], 0, k[1], k[3], 0, 0, 1);
            //distCoeffs = (cv::Mat_<double>(1, 5) << k[4], k[5], k[7], k[8], k[6]);

            Eigen::Matrix3d cameraMatrix_;
            cameraMatrix_ << k[0], 0.0, k[2], 0, k[1], k[3], 0, 0, 1;
            Eigen::VectorXd  distCoeffs_(5);
            distCoeffs_ << k[4], k[5], k[7], k[8], k[6];
            
            std::vector<double> reprojErrs;
            double totalAvgErr = computeReprojectionErrors(objectPoints, imagePoints, rList, tList, cameraMatrix_, distCoeffs_, reprojErrs);
            std::cout << " avg re projection error = " << totalAvgErr << std::endl;
            for (size_t i = 0; i < reprojErrs.size(); i++)
            {
                std::cout << i << " projection error = " << reprojErrs[i] << std::endl;
            }

            // Mat
            cv::eigen2cv(cameraMatrix_, cameraMatrix);
            cv::eigen2cv(distCoeffs_, distCoeffs);
        }
    }

}



/**
 * 鱼眼相机标定
 */
void computeFisherCameraCalibration(std::vector<std::vector<Eigen::Vector2d>>& imagePoints,
                                    std::vector<std::vector<Eigen::Vector3d>>& objectPoints, cv::Mat& cameraMatrix, cv::Mat& distCoeffs){

    std::cout << " fit homography ....." << std::endl;
    int n = imagePoints.size();
    std::vector<Eigen::Matrix3d> homos;
    for (int i=0; i<n; ++i)
    {
        Eigen::Matrix3d H;
        std::vector<Eigen::Vector2d> objectPoints2d;
        for(auto& v: objectPoints[i]) {
            objectPoints2d.push_back(Eigen::Vector2d(v(0), v(1)));
        }
        bool ok = findHomography( objectPoints2d,imagePoints[i], H, true);
        //findHomographyByOpenCV(objectPoints2d,imagePoints[i], H);
        homos.push_back(H);
    }
    std::cout << " fit homography finished" << std::endl;

    // 计算相机内参初始值
    std::cout << " solve init camera intrinsic ..." << std::endl;

    Eigen::Matrix3d K = solveInitCameraIntrinsic(homos);

    std::cout << "init k" << K << std::endl;
    // 计算每组的外参（旋转矩阵和平移向量）
    std::vector<Matrix3d> RList;
    std::vector<Vector3d> tList;
    std::cout << " solve init camera extrinsic ..." << std::endl;
    solveInitCameraExtrinsic(homos, K, RList, tList);
    std::cout << " solve init camera extrinsic finished" << std::endl;
    std::vector<Vector3d> rList;
    for(auto& item: RList) {
        Vector3d _r = rotationMatrix2Vector(item);
        rList.push_back(_r);
    }
    std::cout << " solve ceres::Solver::Options ..." << std::endl;

    // 优化算法
    {
        //
        ceres::Problem problem;
        double k[8] = {K(0,0), K(1,1), K(0,2), K(1,2), 0., 0., 0., 0.};


        for(int i=0; i<n; ++i) {


            for(int j=0; j<imagePoints[i].size(); ++j) {

                ceres::CostFunction* costFunction=new ceres::AutoDiffCostFunction<FISHER_PROJECT_COST, 2, 8, 3, 3>(
                        new FISHER_PROJECT_COST(objectPoints[i][j], imagePoints[i][j]));

                problem.AddResidualBlock(costFunction,
                                         nullptr,
                                         k,
                                         rList[i].data(),
                                         tList[i].data()
                );

            }
        }
        std::cout << " solve Options ..." << std::endl;

        ceres::Solver::Options options;
        options.minimizer_progress_to_stdout = true;
        //options.linear_solver_type = ceres::DENSE_SCHUR;
        //options.trust_region_strategy_type = ceres::TrustRegionStrategyType::LEVENBERG_MARQUARDT;
        //options.preconditioner_type = ceres::JACOBI;
        //options.sparse_linear_algebra_library_type = ceres::EIGEN_SPARSE;
        ceres::Solver::Summary summary;
        ceres::Solve(options, &problem, &summary);
        std::cout << summary.BriefReport() << std::endl;


        if (!summary.IsSolutionUsable())
        {
            std::cout << "Bundle Adjustment failed." << std::endl;
        }
        else
        {
            //summary.num_
            // Display statistics about the minimization
            std::cout << std::endl
                      << "Bundle Adjustment statistics (approximated RMSE):\n"
                      << " #views: " << n << "\n"
                      << " #residuals: " << summary.num_residuals << "\n"
                      << " #num_parameters: " << summary.num_parameters << "\n"
                      << " #num_parameter_blocks: " << summary.num_parameter_blocks << "\n"
                      << " Initial RMSE: " << std::sqrt(summary.initial_cost / summary.num_residuals) << "\n"
                      << " Final RMSE: " << std::sqrt(summary.final_cost / summary.num_residuals) << "\n"
                      << " Time (s): " << summary.total_time_in_seconds << "\n"
                      << std::endl;

            for(auto& a: k) std::cout << a << " " ;

            //cv::Mat cameraMatrix, distCoeffs;
            //cameraMatrix = (cv::Mat_<double>(3, 3) << k[0], 0.0, k[2], 0, k[1], k[3], 0, 0, 1);
            //distCoeffs = (cv::Mat_<double>(1, 5) << k[4], k[5], k[7], k[8], k[6]);

            Eigen::Matrix3d cameraMatrix_;
            cameraMatrix_ << k[0], 0.0, k[2], 0, k[1], k[3], 0, 0, 1;
            Eigen::Vector4d distCoeffs_;
            distCoeffs_ << k[4], k[5], k[6], k[7];




            std::vector<double> reprojErrs;
            double totalAvgErr = computeFisherReprojectionErrors(objectPoints, imagePoints, rList, tList, cameraMatrix_, distCoeffs_, reprojErrs);
            std::cout << " avg re projection error = " << totalAvgErr << std::endl;
            for (size_t i = 0; i < reprojErrs.size(); i++)
            {
                std::cout << i << " projection error = " << reprojErrs[i] << std::endl;
            }

            // Mat
            cv::eigen2cv(cameraMatrix_, cameraMatrix);
            cv::eigen2cv(distCoeffs_, distCoeffs);

        }
    }

}

